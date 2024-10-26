/// represents an immutable, reference-counted OSC message
pub const Message = struct {
    path: [:0]const u8,
    types: [:0]const u8,

    const Header = struct {
        msg: Message,
        rc: RefCount(Header, "rc", destroy),
        size: usize,
        data_offset: usize,

        fn destroy(self: *Header, allocator: std.mem.Allocator) void {
            const allocation: [*]align(@max(4, @alignOf(Header))) const u8 = @ptrCast(@alignCast(self));
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
        const allocation = try allocator.alignedAlloc(u8, @max(4, @alignOf(Header)), pad(buffer.len) + pad(@sizeOf(Header)));
        errdefer allocator.free(allocation);
        const header: *Header = @ptrCast(allocation.ptr);
        if (buffer[0] != '/') return error.BadBufferData;
        const address_len = std.mem.indexOfScalar(u8, buffer, 0) orelse return error.BadBufferData;
        const types_offset = pad(address_len);
        if (buffer[types_offset] != ',') return error.BadBufferData;
        const types_len = std.mem.indexOfScalar(u8, buffer[types_offset + 1 ..], 0) orelse return error.BadBufferData;
        const msg_start = pad(@sizeOf(Header));
        @memcpy(allocation[msg_start..][0..buffer.len], buffer);
        @memset(allocation[msg_start + buffer.len ..], 0);
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
};

fn pad(size: usize) usize {
    if (size == 0) return 0;
    return size + 4 - (size % 4);
}

fn RefCount(comptime T: type, comptime field_name: []const u8, comptime deinitFn: fn (this: *T, allocator: std.mem.Allocator) void) type {
    return struct {
        allocator: std.mem.Allocator,
        ref_count: usize,

        const Self = @This();

        pub fn ref(self: *Self) void {
            self.ref_count += 1;
        }

        pub fn unref(self: *Self) void {
            std.debug.assert(self.ref_count > 0);
            self.ref_count -= 1;
            if (self.ref_count > 0) return;
            const parent: *T = @fieldParentPtr(field_name, self);
            @call(.always_inline, deinitFn, .{ parent, self.allocator });
        }
    };
}

pub const TimeTag = packed struct {
    seconds: u32,
    frac: u32,

    pub const immediately: TimeTag = .{
        .seconds = 0,
        .frac = 1,
    };

    pub fn getEpochInstant() std.time.Instant {
        const is_posix = switch (builtin.os.tag) {
            .wasi => builtin.link_libc,
            .windows => false,
            else => true,
        };
        return .{
            .timestamp = if (is_posix) .{ .tv_sec = 0, .tv_nsec = 0 } else 0,
        };
    }

    /// converts a time expressed as nanoseconds since UTC 1970-01-01 into an OSC (NTP) timetag
    /// time must be after UTC 1900-01-01
    pub fn fromNanoTimestamp(nanoseconds: i128) Data {
        const seconds_since_unix_epoch = @divFloor(nanoseconds, std.time.ns_per_s);
        const seconds_since_ntp_epoch = seconds_since_unix_epoch + std.time.epoch.ntp;
        const remaining_nanoseconds = nanoseconds % std.time.ns_per_s;
        const ticks_per_second = std.math.maxInt(u32) + 1;
        const ticks_per_nanosecond = @divFloor(ticks_per_second, std.time.ns_per_s);
        return .{ .t = .{
            .seconds = @intCast(seconds_since_ntp_epoch),
            .frac = @intCast(remaining_nanoseconds * ticks_per_nanosecond),
        } };
    }

    /// converts a time expressed as seconds since UTC 1970-01-01 into an OSC (NTP) timetag
    /// time must be after UTC 1900-01-01
    pub fn fromTimestamp(seconds: i64) Data {
        const seconds_since_ntp_epoch = seconds + std.time.epoch.ntp;
        return .{ .t = .{
            .seconds = @intCast(seconds_since_ntp_epoch),
            .frac = 0,
        } };
    }
};

pub const Data = union(enum) {
    i: i32,
    f: f32,
    s: []const u8,
    h: i64,
    b: []const u8,
    t: TimeTag,
    d: f64,
    S: []const u8,
    c: u8,
    m: [4]u8,
    T: void,
    F: void,
    N: void,
    I: void,
    r: u32,

    pub fn format(self: Data, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self) {
            .T => try writer.writeAll("true"),
            .F => try writer.writeAll("false"),
            .N => try writer.writeAll("nil"),
            .I => try writer.writeAll("bang"),
            .r => |r| try writer.print("#{x}", .{r}),
            .c => |c| try writer.print("'{c}'", .{c}),
            .m => |m| try writer.print("0x{x} 0x{x} 0x{x} 0x{x}", .{ m[0], m[1], m[2], m[3] }),
            .S => |s| try writer.print("symbol: {s}", .{s}),
            .s => |s| try writer.print("{s}", .{s}),
            .b => |b| try writer.print("blob: length: {d}\n{x}", .{ b.len, b }),
            .t => |t| try writer.print("seconds since UTC 1970-01-01: {d}, {d} ticks", .{ t.seconds, t.frac }),
            inline .h, .i, .f, .d => |i| try writer.print("{d}", .{i}),
        }
    }

    pub fn eql(a: Data, b: Data) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            inline .i, .f, .h, .d, .c, .r => |val, tag| val == @field(b, @tagName(tag)),
            inline .s, .S, .b => |string, tag| std.mem.eql(u8, string, @field(b, @tagName(tag))),
            .m => |midi| std.mem.eql(u8, &midi, &b.m),
            .t => |time| @as(u64, @bitCast(time)) == @as(u64, @bitCast(b.t)),
            .T, .F, .N, .I => true,
        };
    }

    /// treats all ints as i, all floats as f, all pointers as s, booleans as T or F, null as N, and all enum literals as I
    /// for more sensitive constructions, initiate manually
    pub fn from(comptime T: type, item: T) Data {
        const info = @typeInfo(T);
        return switch (info) {
            .Int => .{ .i = @intCast(item) },
            .ComptimeInt => .{ .i = item },
            .Float => .{ .f = @floatCast(item) },
            .ComptimeFloat => .{ .f = item },
            .Pointer => .{ .s = item },
            .Bool => if (item) .T else .F,
            .Null => .N,
            .EnumLiteral => .I,
            else => @compileError("cannot produce Data from this type!"),
        };
    }

    pub fn write(self: Data, writer: anytype) !usize {
        return switch (self) {
            .T, .F, .N, .I => 0,
            .c => |byte| blk: {
                try writer.writeByte(byte);
                try writer.writeByteNTimes(0, 3);
                break :blk 4;
            },
            .m => |msg| blk: {
                try writer.writeAll(&msg);
                break :blk 4;
            },
            inline .f, .d => |float| blk: {
                const T = @TypeOf(float);
                const size = @divExact(@typeInfo(T).Float.bits, 8);
                const I = @Type(.{ .Int = .{
                    .bits = size * 8,
                    .signedness = .unsigned,
                } });
                const bytes: I = @bitCast(float);
                try writer.writeInt(I, bytes, .big);
                break :blk size;
            },
            inline .i, .h, .r => |int| blk: {
                const T = @TypeOf(int);
                const size = @divExact(@typeInfo(T).Int.bits, 8);
                try writer.writeInt(T, int, .big);
                break :blk size;
            },
            .s, .S => |string| blk: {
                const pad_len = pad(string.len);
                try writer.writeAll(string);
                try writer.writeByteNTimes(0, pad_len - string.len);
                break :blk pad_len;
            },
            .b => |blob| blk: {
                const size: i32 = @intCast(blob.len);
                const rem = 4 - (blob.len % 4);
                try writer.writeInt(i32, size, .big);
                try writer.writeAll(blob);
                try writer.writeByteNTimes(0, rem);
                break :blk 4 + blob.len + rem;
            },
            .t => |timetag| blk: {
                try writer.writeInt(u64, @bitCast(timetag), .big);
                break :blk 8;
            },
        };
    }
};

test {
    _ = Message;
}

const std = @import("std");
const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();
