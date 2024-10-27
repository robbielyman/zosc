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
    const allocation = try allocator.alignedAlloc(u8, @max(4, @alignOf(Header)), buffer.len + pad(@sizeOf(Header)));
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
    const args = try msg.getArgs(std.testing.allocator);
    defer std.testing.allocator.free(args);
    try std.testing.expectEqualStrings("/test/path", msg.path);
    try std.testing.expectEqualStrings("s", msg.types);
    try std.testing.expectEqual(1, args.len);
    try std.testing.expectEqualStrings("abc", args[0].s);
}

/// caller owns the returned slice.
/// however, pointers in the returned Data object are not owned by the caller;
/// instead their lifetime is equal to and managed by the lifetime of `self`.
pub fn getArgs(self: *const Message, allocator: std.mem.Allocator) (std.mem.Allocator.Error || error{MessageDataCorrupt})![]const Data {
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

test getArgs {
    const msg = try Message.fromTuple(std.testing.allocator, "/test/path", .{ 1, 1.2, "string", true, false, null, .infinitum });
    defer msg.unref();
    const args = try msg.getArgs(std.testing.allocator);
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

pub fn build(allocator: std.mem.Allocator, path: []const u8, types: []const u8, data: []const u8) std.mem.Allocator.Error!*Message {
    const path_len = pad(path.len);
    const types_len = pad(types.len + 1);
    const data_len = pad(data.len);
    const header_len = pad(@sizeOf(Header));
    const size = path_len + types_len + data_len + header_len;
    const allocation = try allocator.alignedAlloc(u8, @max(4, @alignOf(Header)), size);
    const header: *Header = @ptrCast(allocation.ptr);
    var ptr: [*]u8 = allocation.ptr + header_len;
    @memcpy(ptr, path);
    @memset(ptr[path.len..path_len], 0);
    ptr += path_len;
    ptr[0] = ',';
    @memcpy(ptr[1..], types);
    @memset(ptr[types.len + 1 .. types_len], 0);
    ptr += types_len;
    @memcpy(ptr, data);
    if (data_len > data.len) @memset(ptr[data.len..data_len], 0);
    header.* = .{
        .msg = .{
            .path = allocation[header_len..][0..path.len :0],
            .types = allocation[header_len + path_len + 1 ..][0..types.len :0],
        },
        .rc = .{
            .allocator = allocator,
            .ref_count = 1,
        },
        .size = size,
        .data_offset = header_len + path_len + types_len,
    };
    return &header.msg;
}

pub fn fromTuple(allocator: std.mem.Allocator, path: []const u8, tuple: anytype) std.mem.Allocator.Error!*Message {
    var builder = try Builder.fromTuple(allocator, tuple);
    defer builder.deinit();
    return try builder.commit(allocator, path);
}

test fromTuple {
    const msg = try Message.fromTuple(std.testing.allocator, "/test/path", .{
        1, 1.2, "string", true, false, null, .infinitum,
    });
    defer msg.unref();
}

pub const Builder = struct {
    allocator: std.mem.Allocator,
    data: std.ArrayListUnmanaged(Data),

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{
            .allocator = allocator,
            .data = .{},
        };
    }

    pub fn deinit(self: *Builder) void {
        self.data.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn commit(self: *const Builder, allocator: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error!*Message {
        const types = try self.allocator.alloc(u8, self.data.items.len);
        defer self.allocator.free(types);
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        const writer = buf.writer();
        for (self.data.items, 0..) |datum, i| {
            _ = try datum.write(writer);
            types[i] = @tagName(datum)[0];
        }
        return try Message.build(allocator, path, types, buf.items);
    }

    pub fn append(self: *Builder, datum: Data) std.mem.Allocator.Error!void {
        try self.data.append(self.allocator, datum);
    }

    pub fn appendSlice(self: *Builder, slice: []const Data) std.mem.Allocator.Error!void {
        try self.data.appendSlice(self.allocator, slice);
    }

    pub fn fromTuple(allocator: std.mem.Allocator, tuple: anytype) std.mem.Allocator.Error!Builder {
        var self: Builder = .{
            .allocator = allocator,
            .data = .{},
        };
        errdefer self.deinit();
        const info = @typeInfo(@TypeOf(tuple)).Struct;
        comptime std.debug.assert(info.is_tuple);
        inline for (info.fields, 0..) |field, i| {
            try self.append(Data.from(field.type, tuple[i]));
        }
        return self;
    }
};

test Builder {
    var builder = Builder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.append(.{ .S = "symbol" });
    const msg = try builder.commit(std.testing.allocator, "/first/msg");
    defer msg.unref();
    try builder.appendSlice(&.{
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
