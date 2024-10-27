pub const Parse = union {
    bundle: BundleIterator,
    message: MessageIterator,

    pub const BundleIterator = struct {
        time: TimeTag,
        contents: []const u8,
        offset: usize,

        pub fn next(self: *BundleIterator) error{InvalidOSC}!?[]const u8 {
            if (self.offset >= self.contents.len) return null;
            const advance = std.math.cast(usize, std.mem.readInt(i32, self.contents[self.offset..][0..4], .big)) orelse return error.InvalidOSC;
            if (advance % 4 != 0) return error.InvalidOSC;
            const ret = self.contents[self.offset..][0..advance];
            self.offset += advance;
            return ret;
        }

        pub fn reset(self: *BundleIterator) void {
            self.offset = 16;
        }
    };

    pub const MessageIterator = struct {
        path: []const u8,
        types: []const u8,
        contents: []const u8,
        arg_offset: usize,
        offset: usize,

        pub fn next(self: *MessageIterator) error{InvalidOSC}!?Data {
            if (self.arg_offset >= self.types.len) return null;
            const tag = std.meta.intToEnum(TypeTag, self.types[self.arg_offset]) catch return error.InvalidOSC;
            return switch (tag) {
                inline .T, .F, .N, .I => |t| res: {
                    self.arg_offset += 1;
                    break :res @unionInit(Data, @tagName(t), {});
                },
                inline .i, .f, .r, .h, .d => |t| res: {
                    self.arg_offset += 1;
                    const size = comptime t.sizeOf().?;
                    const unsigned: if (size == 4) u32 else u64 = @bitCast(self.contents[self.offset..][0..size].*);
                    self.offset += size;
                    break :res @unionInit(Data, @tagName(t), @bitCast(if (native_endian == .big) unsigned else @bitReverse(unsigned)));
                },
                .m => res: {
                    self.arg_offset += 1;
                    const res: Data = .{ .m = self.contents[self.offset..][0..4].* };
                    self.offset += 4;
                    break :res res;
                },
                .c => res: {
                    self.arg_offset += 1;
                    const res: Data = .{ .c = self.contents[self.offset] };
                    self.offset += 4;
                    break :res res;
                },
                inline .s, .S => |t| res: {
                    self.arg_offset += 1;
                    const end_index = std.mem.indexOfScalarPos(u8, self.contents, self.offset, 0);
                    const res = @unionInit(Data, @tagName(t), self.contents[self.offset..end_index]);
                    self.offset = pad(end_index);
                    break :res res;
                },
                .b => res: {
                    self.arg_offset += 1;
                    const size = std.math.cast(usize, std.mem.readInt(i32, self.contents[self.offset..][0..4], .big)) orelse return error.InvalidOSC;
                    const res: Data = .{ .b = self.contents[self.offset + 4 ..][0..size] };
                    self.offset += 4 + pad(size);
                    break :res res;
                },
            };
        }

        pub fn reset(self: *MessageIterator) void {
            self.arg_offset = 0;
            self.offset = pad(self.path.len) + pad(self.types.len + 1);
        }
    };
};

pub fn parseOSC(bytes: []const u8) error{InvalidOSC}!Parse {
    return switch (bytes[0]) {
        '/' => msg: {
            const path_end = std.mem.indexOfScalar(u8, bytes, 0) orelse return error.InvalidOSC;
            const path = bytes[0..path_end];
            const types_offset = pad(path_end);
            if (bytes[types_offset] != ',') return error.InvalidOSC;
            const types_end = std.mem.indexOfScalarPos(u8, bytes, types_offset, 0) orelse return error.InvalidOSC;
            break :msg .{ .message = .{
                .path = path,
                .types = bytes[types_offset + 1 .. types_end],
                .contents = bytes,
                .offset = pad(types_end),
                .arg_offset = 0,
            } };
        },
        '#' => bundle: {
            if (!std.mem.startsWith(u8, bytes, "#bundle\x00")) return error.InvalidOSC;
            break :bundle .{ .bundle = .{
                .time = @bitCast(std.mem.readInt(u64, bytes[8..16], .big)),
                .contents = bytes,
                .offset = 16,
            } };
        },
        else => error.InvalidOSC,
    };
}

const std = @import("std");
const data = @import("data.zig");
const TimeTag = data.TimeTag;
const TypeTag = data.TypeTag;
const Data = data.Data;
const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();

fn pad(size: usize) usize {
    if (size == 0) return size;
    return size + 4 - (size % 4);
}
