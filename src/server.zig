const Server = @This();

pub const Entry = struct {
    pattern: ?[]const u8,
    types: ?[]const u8,
    method: ?*const Method,
    userdata: ?*anyopaque,
};

list: std.ArrayList(Entry),
handler: *const ErrorHandlerFn,

pub fn init(allocator: std.mem.Allocator) Server {
    return .{
        .list = std.ArrayList(Entry).init(allocator),
        .handler = m.defaultErrorHandler,
    };
}

pub fn deinit(self: *Server) void {
    self.list.deinit();
    self.* = undefined;
}

pub fn register(self: *Server, pattern: ?[]const u8, types: ?[]const u8, method: *const Method, userdata: *anyopaque) std.mem.Allocator.Error!?Entry {
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
    try self.list.append(.{
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
                if (entry.types) |types| if (!matchTypes(types, msg.types)) {
                    switch (try self.handler(error.MismatchedTypes)) {
                        .yes => continue,
                        .no => return,
                    }
                };
                const keep_going = method(entry.userdata, msg) catch |err| try self.handler(err);
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

pub const ErrorHandlerFn = fn (err: anyerror) anyerror!Continue;

pub fn defaultErrorHandler(err: anyerror) anyerror!Continue {
    if (err == error.MismatchedTypes) return .yes;
    return err;
}

const m = @import("method.zig");
const matchPath = m.matchPath;
const matchTypes = m.matchTypes;
const Method = m.Method;
const std = @import("std");
const parse = @import("parse.zig");
const parseOSC = parse.parseOSC;
const TimeTag = @import("data.zig").TimeTag;
