pub const TypeTag = enum(u8) {
    i = 'i',
    f = 'f',
    s = 's',
    h = 'h',
    b = 'b',
    t = 't',
    d = 'd',
    S = 'S',
    c = 'c',
    m = 'm',
    T = 'T',
    F = 'F',
    N = 'N',
    I = 'I',
    r = 'r',

    pub fn sizeOf(tag: TypeTag) ?usize {
        return switch (tag) {
            .T, .F, .N, .I => 0,
            .i, .f, .r, .m, .c => 4,
            .h, .d, .t => 8,
            .s, .b, .S => null,
        };
    }
};

pub const Data = union(TypeTag) {
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
            inline .i, .h, .r => |int, tag| blk: {
                const T = @TypeOf(int);
                try writer.writeInt(T, int, .big);
                break :blk tag.sizeOf().?;
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

const std = @import("std");
const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();

fn pad(size: usize) usize {
    if (size == 0) return size;
    return size + 4 - (size % 4);
}
