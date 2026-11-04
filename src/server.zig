const Server = @This();

/// Entries do not own the memory pointed to by their fields,
/// but valid Entries require the lifetime of their fields to extend to the lifetime of the Entry
pub const Entry = struct {
    pattern: ?[]const u8,
    types: ?[]const u8,
    method: ?*const Method,
    userdata: ?*anyopaque,
};

list: std.ArrayList(Entry),

pub const init: Server = .{ .list = .empty };

pub fn deinit(self: *Server, allocator: std.mem.Allocator) void {
    self.list.deinit(allocator);
    self.* = undefined;
}

pub fn register(self: *Server, allocator: std.mem.Allocator, pattern: ?[]const u8, types: ?[]const u8, method: *const Method, userdata: ?*anyopaque) std.mem.Allocator.Error!?Entry {
    if (self.find(pattern)) |entry| {
        const ret = entry.*;
        entry.* = .{
            .pattern = pattern,
            .types = types,
            .method = method,
            .userdata = userdata,
        };
        return ret;
    }
    try self.list.append(allocator, .{
        .pattern = pattern,
        .types = types,
        .method = method,
        .userdata = userdata,
    });
    return null;
}

pub fn find(self: *Server, pattern: ?[]const u8) ?*Entry {
    for (self.list.items) |*entry| {
        if (pattern) |p| {
            if (entry.pattern) |q|
                if (std.mem.eql(u8, p, q)) return entry;
        } else if (entry.pattern == null) return entry;
    }
    return null;
}

pub fn dispatch(self: *Server, content: []const u8, now: TimeTag) !void {
    var parsed = try parseOSC(content);
    switch (parsed) {
        .message => |*msg| {
            for (self.list.items) |entry| {
                const method = entry.method orelse continue;
                if (entry.pattern) |pattern| if (!matchPath(pattern, msg.path)) continue;
                if (entry.types) |types| if (!matchTypes(types, msg.types)) continue;
                const keep_going = method(entry.userdata, msg) catch |err| switch (err) {
                    error.MismatchedTypes => .yes,
                    else => return err,
                };
                if (keep_going == .no) return;
            }
        },
        .bundle => |*bndl| {
            const is_immediately = bndl.time.seconds == 0 and bndl.time.frac == 1;
            const is_ready = bndl.time.seconds < now.seconds or (bndl.time.seconds == now.seconds and bndl.time.frac <= now.frac);
            if (!is_immediately and !is_ready) return error.NotYet;
            while (try bndl.next()) |element| self.dispatch(element, now) catch |err| {
                if (err == error.NotYet) continue;
                return err;
            };
        },
    }
}

pub const Continue = enum { yes, no };

test "basic Server" {
    const allocator = std.testing.allocator;
    var s: Server = .init;
    defer s.deinit(allocator);
    var okay = false;
    const method = struct {
        fn f(ud: ?*anyopaque, mi: *parse.Parse.MessageIterator) !Continue {
            const b: *bool = @ptrCast(ud);
            b.* = switch (try mi.next() orelse return error.NoArgument) {
                .F => false,
                .T => true,
                else => return error.BadArgument,
            };
            return .no;
        }
    }.f;
    const r = try s.register(allocator, "/pass_test", "b", method, &okay);
    if (r != null) return error.Fail;
    const message = try @import("message.zig").fromTuple(allocator, "/pass_test", .{true});
    defer message.unref();
    try s.dispatch(message.toBytes(), .immediately);
}

const m = @import("method.zig");
const matchPath = m.matchPath;
const matchTypes = m.matchTypes;
const Method = m.Method;
const std = @import("std");
const parse = @import("parse.zig");
const parseOSC = parse.parseOSC;
const TimeTag = @import("data.zig").TimeTag;
