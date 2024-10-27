pub const Bang = error{Bang};

pub const Method = fn (*anyopaque, *MessageIterator) anyerror!Continue;

fn Fn(comptime types: []const u8) type {
    var index: usize = 0;
    var args: []const std.builtin.Type.Fn.Param = &.{
        .{ .is_generic = false, .is_noalias = false, .type = *anyopaque },
        .{ .is_generic = false, .is_noalias = false, .type = []const u8 },
    };
    while (index < types.len) : (index += 1) {
        const t = switch (types[index]) {
            'i' => i32,
            'f' => f32,
            's', 'S', 'b' => []const u8,
            't' => TimeTag,
            'd' => f64,
            'c' => u8,
            'm' => [4]u8,
            'r' => u32,
            'B', 'T', 'F' => bool,
            'I' => Bang,
            '?' => inner: {
                index += 1;
                const inner = switch (types[index]) {
                    'i' => i32,
                    'f' => f32,
                    's', 'S', 'b' => []const u8,
                    't' => TimeTag,
                    'd' => f64,
                    'c' => u8,
                    'm' => [4]u8,
                    'r' => u32,
                    'B', 'T', 'F' => bool,
                    'I' => Bang,
                    else => @compileError("bad type descriptor!"),
                };
                break :inner @Type(.{ .Optional = .{ .child = inner } });
            },
            '!' => inner: {
                index += 1;
                const inner = switch (types[index]) {
                    'i' => i32,
                    'f' => f32,
                    's', 'S', 'b' => []const u8,
                    't' => TimeTag,
                    'd' => f64,
                    'c' => u8,
                    'm' => [4]u8,
                    'r' => u32,
                    'B', 'T', 'F' => bool,
                    'I' => Bang,
                    '?' => double_inner: {
                        index += 1;
                        const double_inner = switch (types[index]) {
                            'i' => i32,
                            'f' => f32,
                            's', 'S', 'b' => []const u8,
                            't' => TimeTag,
                            'd' => f64,
                            'c' => u8,
                            'm' => [4]u8,
                            'r' => u32,
                            'B', 'T', 'F' => bool,
                            'I' => Bang,
                            else => @compileError("bad type descriptor!"),
                        };
                        break :double_inner @Type(.{ .Optional = .{ .child = double_inner } });
                    },
                    else => @compileError("bad type descriptor!"),
                };
                break :inner @Type(.{ .ErrorUnion = .{
                    .error_set = Bang,
                    .payload = inner,
                } });
            },
        };
        args = args ++ .{.{ .is_generic = false, .is_noalias = false, .type = t }};
    }
    return @Type(.{ .Fn = .{
        .calling_convention = .Unspecified,
        .is_generic = false,
        .is_var_args = false,
        .return_type = anyerror!Continue,
        .params = args,
    } });
}

fn matchPiece(pattern: []const u8, piece: []const u8) bool {
    var pattern_idx: usize = 0;
    var piece_idx: usize = 0;
    while (pattern_idx < pattern.len) : (pattern_idx += 1) {
        if (piece_idx >= piece.len) return false;
        switch (pattern[pattern_idx]) {
            '?' => {
                piece_idx += 1;
            },
            '[' => {
                const byte = piece[piece_idx];
                const end_idx = std.mem.indexOfScalarPos(u8, pattern, pattern_idx, ']') orelse return false;
                const options = pattern[pattern_idx + 1 .. end_idx];
                if (options[0] == '!') {
                    var i: usize = 1;
                    while (i < options.len) : (i += 1) {
                        if (options[i] == '-') {
                            if (i == 1) return false;
                            if (i == options.len - 1) {
                                if (byte == '-') return false;
                            }
                            const prev = options[i - 1];
                            const next = options[i + 1];
                            if (prev <= byte and byte <= next) return false;
                            i += 1;
                        } else {
                            if (byte == options[i]) return false;
                        }
                    }
                } else {
                    var i: usize = 0;
                    while (i < options.len) : (i += 1) {
                        if (options[i] == '-') {
                            if (i == 0) return false;
                            if (i == options.len - 1) {
                                if (byte == '-') break;
                            }
                            const prev = options[i - 1];
                            const next = options[i + 1];
                            if (prev <= byte and byte <= next) break;
                            i += 1;
                        } else {
                            if (byte == options[i]) break;
                        }
                    } else return false;
                }
                pattern_idx = end_idx;
                piece_idx += 1;
            },
            '{' => {
                const end_idx = std.mem.indexOfScalarPos(u8, pattern, pattern_idx, '}') orelse return false;
                var iterator = std.mem.tokenizeScalar(u8, pattern[pattern_idx..end_idx], ',');
                while (iterator.next()) |string| {
                    if (std.mem.startsWith(u8, piece[piece_idx..], string)) {
                        piece_idx += string.len;
                        break;
                    }
                } else return false;
                pattern_idx = end_idx;
            },
            ']', '}' => return false,
            '*' => if (pattern_idx + 1 < pattern.len) {
                for (piece_idx..piece.len) |i| {
                    if (matchPiece(pattern[pattern_idx + 1 ..], piece[i..])) return true;
                } else return false;
            } else return true,
            else => if (pattern[pattern_idx] != piece[piece_idx]) return false else {
                piece_idx += 1;
            },
        }
    }
    return piece_idx >= piece.len;
}

pub fn matchPath(pattern: []const u8, path: []const u8) bool {
    var pattern_iter = std.mem.splitScalar(u8, pattern[1..], '/');
    var path_iter = std.mem.splitScalar(u8, path[1..], '/');
    while (pattern_iter.next()) |pattern_piece| {
        const piece = path_iter.next() orelse return false;
        if (pattern_piece.len == 0) continue;
        if (!matchPiece(pattern_piece, piece)) return false;
    }
    return path_iter.peek() == null;
}

test matchPath {
    const string = "//first/[ab]/[!c-]/[a-z]/[!a-z]/{abba,gabba}";
    const match =
        "/any/first/a/b/z/0/abba";
    const nonmatches: []const []const u8 = &.{
        "/any/first",
        "/any/second",
        "/any/first/c/b/z/0/abba",
        "/any/first/a/-/z/0/abba",
        "/any/first/c/b/0/0/abba",
        "/any/first/c/b/z/z/abba",
        "/any/first/c/b/z/0/yabba",
    };
    try std.testing.expect(matchPath(string, match));
    for (nonmatches) |nonmatch| try std.testing.expect(!matchPath(string, nonmatch));
}

pub fn matchTypes(pattern: []const u8, types: []const u8) bool {
    var index: usize = 0;
    for (types) |byte| {
        if (index >= pattern.len) return false;
        defer index += 1;
        switch (pattern[index]) {
            '!' => {
                index += 1;
                if (byte == 'I') continue;
                switch (pattern[index]) {
                    '?' => {
                        index += 1;
                        if (byte == 'N') continue;
                        switch (pattern[index]) {
                            'F', 'T', 'B' => if (byte != 'T' and byte != 'F') return false,
                            else => if (byte != pattern[index]) return false,
                        }
                    },
                    'F', 'T', 'B' => if (byte != 'T' and byte != 'F') return false,
                    else => if (byte != pattern[index]) return false,
                }
            },
            '?' => {
                index += 1;
                if (byte == 'N') continue;
                switch (pattern[index]) {
                    'F', 'T', 'B' => if (byte != 'T' and byte != 'F') return false,
                    else => if (byte != pattern[index]) return false,
                }
            },
            'F', 'T', 'B' => if (byte != 'T' and byte != 'F') return false,
            else => if (byte != pattern[index]) return false,
        }
    }
    return index >= pattern.len;
}

test matchTypes {
    const pattern = "s!?Bb";
    const matches: []const []const u8 = &.{ "sIb", "sNb", "sTb", "sFb" };
    const nonmatches: []const []const u8 = &.{ "s!b", "s?b", "sBb", "sib", "sT", "sTbb" };
    for (matches) |m| try std.testing.expect(matchTypes(pattern, m));
    for (nonmatches) |m| try std.testing.expect(!matchTypes(pattern, m));
}

pub fn wrap(comptime types: []const u8, @"fn": Fn(types)) Method {
    return struct {
        fn method(ctx: *anyopaque, msg: *MessageIterator) !Continue {
            const info = @typeInfo(Fn(types)).Fn.params;
            var fields: [info.len]std.builtin.Type.StructField = undefined;
            for (info, 0..) |param, i| {
                fields[i] = .{
                    .name = &.{},
                    .type = param.type.?,
                    .default_value = null,
                    .is_comptime = false,
                    .alignment = @alignOf(param.type.?),
                };
            }
            const ArgsType = @Type(.{ .Struct = .{
                .layout = .auto,
                .is_tuple = true,
                .decls = &.{},
                .fields = &fields,
            } });
            if (!matchTypes(types, msg.types)) return error.TypesMismatch;
            var args: ArgsType = undefined;
            args[0] = ctx;
            args[1] = msg.path;
            for (2..fields.len) |i| {
                const d = try msg.next();
                args[i] = switch (d.?) {
                    .T => true,
                    .F => false,
                    .N => null,
                    .I => error.Bang,
                    inline else => |capture| capture,
                };
            }
            return try @call(.always_inline, @"fn", args);
        }
    }.method;
}

test wrap {
    const inner = struct {
        fn f(_: *anyopaque, path: []const u8, s: []const u8, i: i32, float: f32) !Continue {
            if (!std.mem.eql(u8, path, "/test/path")) return .no;
            if (!std.mem.eql(u8, s, "some string")) return error.Mismatch;
            if (i != 5) return error.Mismatch;
            if (float != 3.14) return error.Mismatch;
            return .yes;
        }

        const wrapped = wrap("sif", f);
    };
    const msg = @import("message.zig").fromTuple("/test/path", .{ "some string", 5, 3.14 });
    defer msg.unref();
    var parsed = try parse.parseOSC(msg.toBytes());
    try std.testing.expectEqual(.yes, try inner.wrapped(null, &parsed.message));
}

const Continue = @import("server.zig").Continue;
const parse = @import("parse.zig");
const MessageIterator = parse.Parse.MessageIterator;
const data = @import("data.zig");
const TypeTag = data.TypeTag;
const TimeTag = data.TimeTag;
const std = @import("std");
