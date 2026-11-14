/// represents an immutable, reference-counted OSC message
const Message = @This();

path: []const u8,
types: []const u8,

const Header = struct {
    msg: Message,
    rc: RefCount(Header, "rc", destroy),
    size: usize,
    data_offset: usize,

    fn destroy(self: *Header, allocator: std.mem.Allocator) void {
        const allocation: [*]align(@max(4, @alignOf(Header))) const u8 = @ptrCast(self);
        allocator.free(allocation[0..self.size]);
    }
};

pub fn ref(self: *Message) void {
    const header: *Header = @fieldParentPtr("msg", self);
    header.rc.ref();
}

pub fn unref(self: *Message) void {
    const header: *Header = @fieldParentPtr("msg", self);
    header.rc.unref();
}

/// caller does not own the resulting bytes,
/// which have lifetime equal to the lifetime of the Message
pub fn toBytes(self: *const Message) []const u8 {
    const header: *const Header = @fieldParentPtr("msg", self);
    const allocation: [*]const u8 = @ptrCast(header);
    return allocation[pad(@sizeOf(Header))..header.size];
}

test toBytes {
    const allocator = std.testing.allocator;
    const path = "/test/path";
    const msg = try Message.fromTuple(allocator, path, .{});
    defer msg.unref();
    const bytes = msg.toBytes();
    try std.testing.expectEqual(pad(path.len + 1) + 4, bytes.len);
    try std.testing.expectEqualStrings(path, bytes[0..path.len]);
    try std.testing.expectEqual(',', bytes[pad(path.len + 1)]);
}

pub fn fromBytes(allocator: std.mem.Allocator, buffer: []const u8) (std.mem.Allocator.Error || error{BadBufferData})!*Message {
    if (buffer.len % 4 != 0) return error.BadBufferData;
    if (buffer[0] != '/') return error.BadBufferData;
    const allocation = try allocator.alignedAlloc(u8, .max(.@"4", .fromByteUnits(@alignOf(Header))), buffer.len + pad(@sizeOf(Header)));
    errdefer allocator.free(allocation);
    const header: *Header = @ptrCast(allocation.ptr);
    const address_len = std.mem.indexOfScalar(u8, buffer, 0) orelse return error.BadBufferData;
    const types_offset = pad(address_len);
    if (buffer[types_offset] != ',') return error.BadBufferData;
    const types_len = std.mem.indexOfScalar(u8, buffer[types_offset + 1 ..], 0) orelse return error.BadBufferData;
    const msg_start = pad(@sizeOf(Header));
    @memcpy(allocation[msg_start..][0..buffer.len], buffer);
    header.* = .{
        .msg = .{
            .path = allocation[msg_start..][0..address_len :0],
            .types = allocation[msg_start + types_offset + 1 ..][0..types_len :0],
        },
        .rc = .{
            .allocator = allocator,
            .ref_count = 1,
        },
        .size = allocation.len,
        .data_offset = msg_start + pad(address_len) + pad(types_len + 1),
    };
    return &header.msg;
}

test fromBytes {
    const bytes = "/test/path\x00\x00,s\x00\x00abc\x00";
    const msg = try Message.fromBytes(std.testing.allocator, bytes);
    defer msg.unref();
    const args = try msg.getArgsAlloc(std.testing.allocator);
    defer std.testing.allocator.free(args);
    try std.testing.expectEqualStrings("/test/path", msg.path);
    try std.testing.expectEqualStrings("s", msg.types);
    try std.testing.expectEqual(1, args.len);
    try std.testing.expectEqualStrings("abc", args[0].s);
}

/// caller owns the returned slice.
/// however, pointers in the returned Data object are not owned by the caller;
/// instead their lifetime is equal to and managed by the lifetime of `self`.
pub fn getArgsAlloc(self: *const Message, allocator: std.mem.Allocator) (std.mem.Allocator.Error || error{MessageDataCorrupt})![]const Data {
    const data = try allocator.alloc(Data, self.types.len);
    errdefer allocator.free(data);
    const header: *const Header = @fieldParentPtr("msg", self);
    const allocation_ptr: [*]align(4) const u8 = @ptrCast(header);
    const ptr: []align(4) const u8 = @alignCast(allocation_ptr[header.data_offset..header.size]);
    var index: usize = 0;
    for (self.types, data) |tag, *datum| {
        const advance: usize = switch (tag) {
            'i' => blk: {
                datum.* = .{ .i = std.mem.readInt(i32, ptr[index..][0..4], .big) };
                break :blk 4;
            },
            'f' => blk: {
                const @"u32" = std.mem.readInt(u32, ptr[index..][0..4], .big);
                datum.* = .{ .f = @bitCast(@"u32") };
                break :blk 4;
            },
            's', 'S' => blk: {
                const end_of_string = std.mem.indexOfScalarPos(u8, ptr, index, 0) orelse return error.MessageDataCorrupt;
                const s = ptr[index..end_of_string];
                datum.* = if (tag == 's') .{ .s = s } else .{ .S = s };
                break :blk pad(s.len + 1);
            },
            'h' => blk: {
                datum.* = .{ .h = std.mem.readInt(i64, ptr[index..][0..8], .big) };
                break :blk 8;
            },
            'c' => blk: {
                datum.* = .{ .c = ptr[index] };
                break :blk 4;
            },
            'b' => blk: {
                const size: usize = @intCast(std.mem.readInt(i32, ptr[index..][0..4], .big));
                datum.* = .{ .b = ptr[index + 4 ..][0..size] };
                break :blk pad(size + 4);
            },
            't' => blk: {
                const @"u64" = std.mem.readInt(u64, ptr[index..][0..8], .big);
                datum.* = .{ .t = @bitCast(@"u64") };
                break :blk 8;
            },
            'd' => blk: {
                const @"u64" = std.mem.readInt(u64, ptr[index..][0..8], .big);
                datum.* = .{ .d = @bitCast(@"u64") };
                break :blk 8;
            },
            'm' => blk: {
                datum.* = .{ .m = ptr[index..][0..4].* };
                break :blk 4;
            },
            'r' => blk: {
                datum.* = .{ .r = std.mem.readInt(u32, ptr[index..][0..4], .big) };
                break :blk 4;
            },
            inline 'T', 'F', 'N', 'I' => |which| blk: {
                datum.* = @unionInit(Data, &.{which}, {});
                break :blk 0;
            },
            else => return error.MessageDataCorrupt,
        };
        index += advance;
    }
    return data;
}

test getArgsAlloc {
    const msg = try Message.fromTuple(std.testing.allocator, "/test/path", .{ 1, 1.2, "string", true, false, null, .infinitum });
    defer msg.unref();
    const args = try msg.getArgsAlloc(std.testing.allocator);
    defer std.testing.allocator.free(args);
    const test_args: []const Data = &.{ .{ .i = 1 }, .{ .f = 1.2 }, .{ .s = "string" }, .T, .F, .N, .I };
    for (args, test_args) |got, expected| {
        try std.testing.expect(got.eql(expected));
    }
}

/// NB: performs a deep copy!
pub fn clone(self: *const Message, allocator: std.mem.Allocator) std.mem.Allocator.Error!*Message {
    const bytes = self.toBytes();
    return Message.fromBytes(allocator, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadBufferData => unreachable,
    };
}

/// Writes the raw OSC message with specified path and data.
pub fn fill(w: *std.Io.Writer, path: []const u8, data: []const Data) std.Io.Writer.Error!void {
    _ = try w.writeSplatHeaderLimit(path, &.{&.{0}}, 4, .limited(pad(path.len)));
    try w.writeByte(',');
    // ideally we wouldn't have to loop twice, but writeableSlice is not guaranteed to remain valid through the loop
    for (data) |d| try w.writeByte(@tagName(d)[0]);
    const splat = pad(data.len + 1) - (data.len + 1);
    var to_write: [1][]const u8 = .{&.{0}};
    try w.writeSplatAll(&to_write, splat);
    const Alt = std.fmt.Alt(Data, struct {
        fn f(d: Data, writer: *std.Io.Writer) !void {
            _ = try d.write(writer);
        }
    }.f);
    for (data) |datum| {
        const a: Alt = .{ .data = datum };
        try w.print("{f}", .{a});
    }
}

pub fn build(allocator: std.mem.Allocator, path: []const u8, data: []const Data) !*Message {
    var w: std.Io.Writer.Allocating = .init(allocator);
    defer w.deinit();
    fill(&w.writer, path, data) catch return error.OutOfMemory;
    return try .fromBytes(allocator, w.written());
}

pub fn fromTuple(allocator: std.mem.Allocator, path: []const u8, tuple: anytype) !*Message {
    var alloc: std.Io.Writer.Allocating = .init(allocator);
    defer alloc.deinit();
    fillFromTuple(&alloc.writer, path, tuple) catch return error.OutOfMemory;
    return try .fromBytes(allocator, alloc.written());
}

pub fn fillFromTuple(w: *std.Io.Writer, path: []const u8, tuple: anytype) !void {
    var data = dataFromTuple(tuple);
    var builder: Builder = .init;
    builder.data.items = &data;
    builder.data.capacity = data.len;
    return try builder.write(w, path);
}

pub fn comptimePrint(comptime path: []const u8, comptime tuple: anytype) []align(4) const u8 {
    return comptime compute: {
        var disc: std.Io.Writer.Discarding = .init(&.{});
        try fillFromTuple(&disc.writer, path, tuple);
        var buf: [@intCast(disc.fullCount())]u8 = undefined;
        var buf_writer = std.Io.Writer.failing;
        buf_writer.buffer = &buf;
        try fillFromTuple(&buf_writer, path, tuple);
        const final: [buf.len]u8 align(4) = buf;
        break :compute &final;
    };
}

test comptimePrint {
    const bytes = comptime comptimePrint("/test/path", .{
        1, 2, "string", true, 1.5, false, null, .infinitum,
    });
    const msg = try Message.fromBytes(std.testing.allocator, bytes);
    defer msg.unref();
}

fn dataFromTuple(tuple: anytype) [@typeInfo(@TypeOf(tuple)).@"struct".field_types.len]Data {
    const info = @typeInfo(@TypeOf(tuple)).@"struct";
    comptime std.debug.assert(info.is_tuple);
    var buffer: [info.field_types.len]Data = undefined;
    inline for (&buffer, info.field_types, 0..) |*data, @"type", i| {
        data.* = .from(@"type", tuple[i]);
    }
    return buffer;
}

test fillFromTuple {
    const msg = try Message.fromTuple(std.testing.allocator, "/test/path", .{
        1, 1.2, "string", true, false, null, .infinitum,
    });
    defer msg.unref();
}

pub const Builder = struct {
    data: std.ArrayList(Data),

    pub const init: Builder = .{ .data = .empty };

    pub fn deinit(self: *Builder, allocator: std.mem.Allocator) void {
        self.data.deinit(allocator);
        self.* = undefined;
    }

    pub fn write(self: *const Builder, w: *std.Io.Writer, path: []const u8) !void {
        try fill(w, path, self.data.items);
    }

    pub fn commit(self: *const Builder, allocator: std.mem.Allocator, path: []const u8) !*Message {
        var buf: std.Io.Writer.Allocating = .init(allocator);
        defer buf.deinit();
        self.write(&buf.writer, path) catch return error.OutOfMemory;
        return try .fromBytes(allocator, buf.written());
    }

    pub fn append(self: *Builder, allocator: std.mem.Allocator, datum: Data) std.mem.Allocator.Error!void {
        try self.data.append(allocator, datum);
    }

    pub fn appendSlice(self: *Builder, allocator: std.mem.Allocator, slice: []const Data) std.mem.Allocator.Error!void {
        try self.data.appendSlice(allocator, slice);
    }

    pub fn fromTuple(allocator: std.mem.Allocator, tuple: anytype) std.mem.Allocator.Error!Builder {
        var self: Builder = .init;
        errdefer self.deinit(allocator);
        const data = dataFromTuple(tuple);
        try self.data.ensureUnusedCapacity(allocator, data.len);
        const slice = self.data.addManyAsArrayAssumeCapacity(data.len);
        @memcpy(&slice, &data);
        return self;
    }
};

test Builder {
    var builder: Builder = .init;
    defer builder.deinit(std.testing.allocator);
    try builder.append(std.testing.allocator, .{ .S = "symbol" });
    const msg = try builder.commit(std.testing.allocator, "/first/msg");
    defer msg.unref();
    try builder.appendSlice(std.testing.allocator, &.{
        .{ .i = 1 },
        .{ .i = 2 },
        .{ .i = 3 },
        .{ .f = 1.23456 },
    });
    const other = try builder.commit(std.testing.allocator, "/second/msg");
    defer other.unref();
    try std.testing.expectEqualStrings("S", msg.types);
    try std.testing.expectEqualStrings("Siiif", other.types);
}

const RefCount = @import("RefCount.zig").RefCount;
const std = @import("std");
const Data = @import("data.zig").Data;

fn pad(size: usize) usize {
    if (size == 0) return 0;
    return size + 4 - (size % 4);
}
