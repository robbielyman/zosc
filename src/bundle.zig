/// represents an immutable, reference-counted collection of OSC messages
const Bundle = @This();
time: TimeTag,

const Header = struct {
    bndl: Bundle,
    rc: RefCount(Header, "rc", destroy),
    size: usize,

    fn destroy(self: *Header, allocator: std.mem.Allocator) void {
        const allocation: [*]align(@max(4, @alignOf(Header))) const u8 = @ptrCast(self);
        allocator.free(allocation[0..self.size]);
    }
};

pub fn ref(self: *Bundle) void {
    const header: *Header = @fieldParentPtr("bndl", self);
    header.rc.ref();
}

pub fn unref(self: *Bundle) void {
    const header: *Header = @fieldParentPtr("bndl", self);
    header.rc.unref();
}

/// caller does not own the resulting bytes,
/// which have lifetime equal to the lifetime of the Bundle
pub fn toBytes(self: *const Bundle) []const u8 {
    const header: *const Header = @fieldParentPtr("bnd", self);
    const allocation: [*]const u8 = @ptrCast(header);
    return allocation[pad(@sizeOf(Header))..header.size];
}

pub fn fromBytes(allocator: std.mem.Allocator, buffer: []const u8) (std.mem.Allocator.Error || error{BadBufferData})!*Bundle {
    if (buffer.len % 4 != 0) return error.BadBufferData;
    if (!std.mem.startsWith(u8, buffer, "#bundle\x00")) return error.BadBufferData;
    const allocation = try allocator.alignedAlloc(u8, @max(4, @alignOf(Header)), pad(buffer.len) + pad(@sizeOf(Header)));
    errdefer allocator.free(allocation);
    const header: *Header = @ptrCast(allocation.ptr);
    const time: TimeTag = @bitCast(std.mem.readInt(u64, buffer[8..16], .big));
    @memcpy(allocation[pad(@sizeOf(Header))..], buffer);
    header.* = .{
        .bndl = .{ .time = time },
        .rc = .{
            .allocator = allocator,
            .ref_count = 1,
        },
        .size = allocation.len,
    };
    return &header.bndl;
}

pub fn build(allocator: std.mem.Allocator, tag: TimeTag, content: []const u8) std.mem.Allocator.Error!*Bundle {
    const allocation = try allocator.alignedAlloc(u8, @max(4, @alignOf(Header)), pad(@sizeOf(Header)) + 16 + content.len);
    const header: *Header = @ptrCast(allocation.ptr);
    var ptr: [*]u8 = allocation.ptr + pad(@sizeOf(Header));
    @memcpy(ptr[0..8], "#bundle\x00");
    const unsigned: u64 = @bitCast(tag);
    ptr[8..16].* = if (native_endian == .big) @bitCast(unsigned) else @bitCast(@bitReverse(unsigned));
    @memcpy(ptr[16..], content);
    header.* = .{
        .bndl = .{ .time = tag },
        .rc = .{ .allocator = allocator, .ref_count = 1 },
        .size = pad(@sizeOf(Header)) + 16 + content.len,
    };
    return &header.bndl;
}

pub const Builder = struct {
    data: std.ArrayListAligned(u8, 4),

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{
            .data = std.ArrayListAligned(u8, 4).init(allocator),
        };
    }

    pub fn deinit(self: *Builder) void {
        self.data.deinit();
        self.* = undefined;
    }

    pub fn commit(self: *const Builder, allocator: std.mem.Allocator, time: TimeTag) std.mem.Allocator.Error!*Bundle {
        return try Bundle.build(allocator, time, self.data.items);
    }

    pub fn append(self: *Builder, message_bundle_or_bytes: anytype) std.mem.Allocator.Error!void {
        const T = @TypeOf(message_bundle_or_bytes);
        const bytes = if (T == []const u8) message_bundle_or_bytes else message_bundle_or_bytes.toBytes();
        const size: i32 = @intCast(bytes.len);
        std.debug.assert(@mod(size, 4) == 0);
        const writer = self.data.writer();
        try writer.writeInt(i32, size, .big);
        try writer.writeAll(bytes);
    }
};

test Builder {
    const allocator = std.testing.allocator;
    var builder = Builder.init(allocator);
    defer builder.deinit();
    const msg = try Message.fromTuple(allocator, "/this/is/a/path", .{ 1, 1.5, false, true, null, .bang, "and a string" });
    defer msg.unref();
    try builder.append(msg);
    try builder.append(msg.toBytes());
    const bundle = try builder.commit(allocator, TimeTag.immediately);
    defer bundle.unref();
}

const std = @import("std");
const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();
const TimeTag = @import("data.zig").TimeTag;
const Message = @import("message.zig");
const RefCount = @import("RefCount.zig").RefCount;

fn pad(size: usize) usize {
    if (size == 0) return 0;
    return size + 4 - (size % 4);
}
