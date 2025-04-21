pub const Parse = union(enum) {
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
            const ret = self.contents[self.offset + 4 ..][0..advance];
            self.offset += 4 + advance;
            return ret;
        }

        pub fn reset(self: *BundleIterator) void {
            self.offset = 16;
        }
    };

    pub const MessageIterator = struct {
        path: [:0]const u8,
        types: [:0]const u8,
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
                inline .f, .d => |t| res: {
                    self.arg_offset += 1;
                    const size = comptime t.sizeOf().?;
                    const unsigned = std.mem.readInt(if (size == 4) u32 else u64, self.contents[self.offset..][0..size], .big);
                    self.offset += size;
                    break :res @unionInit(Data, @tagName(t), @bitCast(unsigned));
                },
                inline .i, .r, .h => |t| res: {
                    self.arg_offset += 1;
                    const size = comptime t.sizeOf().?;
                    const T = @TypeOf(@field(@as(Data, undefined), @tagName(t)));
                    const res = @unionInit(Data, @tagName(t), std.mem.readInt(T, self.contents[self.offset..][0..size], .big));
                    self.offset += size;
                    break :res res;
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
                .t => res: {
                    self.arg_offset += 1;
                    const res: Data = .{ .t = @bitCast(std.mem.readInt(u64, self.contents[self.offset..][0..8], .big)) };
                    self.offset += 8;
                    break :res res;
                },
                inline .s, .S => |t| res: {
                    self.arg_offset += 1;
                    const end_index = std.mem.indexOfScalarPos(u8, self.contents, self.offset, 0) orelse return error.InvalidOSC;
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

        pub fn unpack(self: *MessageIterator, comptime types: []const u8) error{ TypeMismatch, InvalidOSC }!Tuple(types) {
            const T = Tuple(types);
            var ret: T = undefined;
            if (!matchTypes(types, self.types)) return error.TypeMismatch;
            const info = @typeInfo(T);
            inline for (info.@"struct".fields, 0..) |field, i| {
                ret[i] = try unpackNext(field.type, self);
            }
            return ret;
        }

        fn unpackNext(comptime T: type, self: *MessageIterator) error{ TypeMismatch, InvalidOSC }!T {
            const datum = try self.next() orelse return error.TypeMismatch;
            const info = @typeInfo(T);
            if (info == .error_union) {
                if (datum == .I) return error.Bang;
                const child_info = @typeInfo(info.error_union.payload);
                if (child_info == .optional) {
                    if (datum == .N) return null;
                    return switch (child_info.optional.child) {
                        i32 => if (datum != .i) error.TypeMismatch else datum.i,
                        f32 => if (datum != .f) error.TypeMismatch else datum.f,
                        []const u8 => switch (datum) {
                            .s, .S, .b => |bytes| bytes,
                            else => error.TypeMismatch,
                        },
                        TimeTag => if (datum != .t) error.TypeMismatch else datum.t,
                        u8 => if (datum != .c) error.TypeMismatch else datum.c,
                        [4]u8 => if (datum != .m) error.TypeMismatch else datum.m,
                        u32 => if (datum != .r) error.TypeMismatch else datum.r,
                        bool => switch (datum) {
                            .T => true,
                            .F => false,
                            else => error.TypeMismatch,
                        },
                        else => @compileError("unexpected type!"),
                    };
                }
                return switch (info.error_union.payload) {
                    i32 => if (datum != .i) error.TypeMismatch else datum.i,
                    f32 => if (datum != .f) error.TypeMismatch else datum.f,
                    []const u8 => switch (datum) {
                        .s, .S, .b => |bytes| bytes,
                        else => error.TypeMismatch,
                    },
                    TimeTag => if (datum != .t) error.TypeMismatch else datum.t,
                    u8 => if (datum != .c) error.TypeMismatch else datum.c,
                    [4]u8 => if (datum != .m) error.TypeMismatch else datum.m,
                    u32 => if (datum != .r) error.TypeMismatch else datum.r,
                    bool => switch (datum) {
                        .T => true,
                        .F => false,
                        else => error.TypeMismatch,
                    },
                    @TypeOf(null) => if (datum != .N) error.TypeMismatch else null,
                    else => @compileError("unexpected type!"),
                };
            }
            if (info == .optional) {
                if (datum == .N) return null;
                return switch (info.optional.child) {
                    i32 => if (datum != .i) error.TypeMismatch else datum.i,
                    f32 => if (datum != .f) error.TypeMismatch else datum.f,
                    []const u8 => switch (datum) {
                        .s, .S, .b => |bytes| bytes,
                        else => error.TypeMismatch,
                    },
                    TimeTag => if (datum != .t) error.TypeMismatch else datum.t,
                    u8 => if (datum != .c) error.TypeMismatch else datum.c,
                    [4]u8 => if (datum != .m) error.TypeMismatch else datum.m,
                    u32 => if (datum != .r) error.TypeMismatch else datum.r,
                    bool => switch (datum) {
                        .T => true,
                        .F => false,
                        else => error.TypeMismatch,
                    },
                    @import("method.zig").Bang => if (datum != .I) error.TypeMismatch else error.Bang,
                    else => @compileError("unexpected type!"),
                };
            }
            return switch (T) {
                i32 => if (datum != .i) error.TypeMismatch else datum.i,
                f32 => if (datum != .f) error.TypeMismatch else datum.f,
                []const u8 => switch (datum) {
                    .s, .S, .b => |bytes| bytes,
                    else => error.TypeMismatch,
                },
                TimeTag => if (datum != .t) error.TypeMismatch else datum.t,
                u8 => if (datum != .c) error.TypeMismatch else datum.c,
                [4]u8 => if (datum != .m) error.TypeMismatch else datum.m,
                u32 => if (datum != .r) error.TypeMismatch else datum.r,
                bool => switch (datum) {
                    .T => true,
                    .F => false,
                    else => error.TypeMismatch,
                },
                @TypeOf(null) => if (datum != .N) error.TypeMismatch else null,
                @import("method.zig").Bang => if (datum != .I) error.TypeMismatch else error.Bang,
                else => @compileError("unexpected type!"),
            };
        }

        fn Unpack(types: []const u8) type {
            comptime {
                var fields: []std.builtin.Type.StructField = &.{};
                for (types, 0..) |byte, i| {
                    const @"type" = switch (byte) {
                        'T', 'F', 'B' => bool,
                        else => blk: {
                            const tag = std.meta.intToEnum(TypeTag, byte) catch @compileError("unknown type tag!");
                            break :blk tag.Type();
                        },
                    };
                    var buf: [4]u8 = undefined;
                    const name = std.fmt.bufPrintZ(&buf, "{d}", .{i}) catch unreachable;
                    const field: std.builtin.Type.StructField = .{
                        .type = @"type",
                        .is_comptime = false,
                        .default_value = null,
                        .name = name,
                        .alignment = @alignOf(@"type"),
                    };
                    fields = fields ++ .{field};
                }
                return @Type(.{ .@"struct" = .{
                    .layout = .auto,
                    .fields = fields,
                    .decls = &.{},
                    .is_tuple = true,
                } });
            }
        }
    };
};

pub fn parseOSC(bytes: []const u8) error{InvalidOSC}!Parse {
    return switch (bytes[0]) {
        '/' => msg: {
            const path_end = std.mem.indexOfScalar(u8, bytes, 0) orelse return error.InvalidOSC;
            const path = bytes[0..path_end :0];
            const types_offset = pad(path_end);
            if (bytes[types_offset] != ',') return error.InvalidOSC;
            const types_end = std.mem.indexOfScalarPos(u8, bytes, types_offset, 0) orelse return error.InvalidOSC;
            break :msg .{ .message = .{
                .path = path,
                .types = bytes[types_offset + 1 .. types_end :0],
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
const Tuple = @import("method.zig").Tuple;
const matchTypes = @import("method.zig").matchTypes;
const TimeTag = data.TimeTag;
const TypeTag = data.TypeTag;
const Data = data.Data;
const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();

fn pad(size: usize) usize {
    if (size == 0) return size;
    return size + 4 - (size % 4);
}

test Parse {
    const root = @import("root.zig");
    const allocator = std.testing.allocator;
    var bndl = root.Bundle.Builder.init(allocator);
    defer bndl.deinit();
    const msg = try root.Message.fromTuple(allocator, "/test/path", .{
        1, 1.5, "string", null, true,
    });
    defer msg.unref();
    try bndl.append(msg);
    const bundle = try bndl.commit(allocator, TimeTag.immediately);
    defer bundle.unref();
    var iter = switch (try parseOSC(bundle.toBytes())) {
        .bundle => |b| b,
        .message => return error.Fail,
    };
    while (try iter.next()) |bytes| {
        var inner = switch (try parseOSC(bytes)) {
            .bundle => return error.Fail,
            .message => |m| m,
        };
        const i, const f, const s, const n, const t = try inner.unpack("ifs?tB");
        try std.testing.expectEqual(1, i);
        try std.testing.expectApproxEqAbs(1.5, f, 0.000001);
        try std.testing.expectEqualStrings("string", s);
        try std.testing.expectEqual(null, n);
        try std.testing.expectEqual(true, t);
    }
}
