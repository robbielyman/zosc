const zosc = @import("zosc");
const std = @import("std");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const which: Which = if (std.mem.endsWith(u8, args[0], "zoscdump")) .dump else .send;
    if (args.len < 3) try printUsageAndExit(which);

    const port = std.fmt.parseInt(u16, args[2], 10) catch {
        try printUsageAndExit(which);
    };
    const addr = std.net.Address.parseIp(args[1], port) catch |err| {
        std.log.err("error parsing IP address: {s}", .{@errorName(err)});
        try printUsageAndExit(which);
    };
    const socket = try std.posix.socket(addr.any.family, std.posix.SOCK.CLOEXEC | std.posix.SOCK.DGRAM, 0);
    defer std.posix.close(socket);
    try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
    try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

    switch (which) {
        .dump => {
            try std.posix.bind(socket, &addr.any, addr.getOsSockLen());
            const stdout_file = std.io.getStdOut().writer();
            var bw = std.io.bufferedWriter(stdout_file);
            const stdout = bw.writer();

            var buffer = try std.ArrayList(u8).initCapacity(allocator, 0xffff);
            defer buffer.deinit();

            while (true) {
                const len = try std.posix.recv(socket, buffer.unusedCapacitySlice(), 0);
                buffer.items.len += len;
                defer buffer.clearRetainingCapacity();
                const msg = zosc.Message.fromBytes(allocator, buffer.items) catch {
                    std.log.err("error while parsing message:\n{s}", .{buffer.items});
                    continue;
                };
                defer msg.unref();
                try stdout.print(
                    \\OSC MESSAGE:
                    \\path: {s}
                    \\arg types: {s}
                    \\
                , .{ msg.path, msg.types });
                if (msg.types.len > 0) {
                    const msg_args = try msg.getArgsAlloc(allocator);
                    defer allocator.free(msg_args);
                    for (msg_args) |arg| {
                        try stdout.print("{}\n", .{arg});
                    }
                }
                try bw.flush();
            }
        },
        .send => {
            try std.posix.connect(socket, &addr.any, addr.getOsSockLen());
            if (args.len < 4) try printUsageAndExit(which);
            const msg: *zosc.Message = if (args.len == 4)
                try zosc.Message.fromTuple(allocator, args[3], .{})
            else msg: {
                const types = args[4];
                if (args.len < 5 + types.len) try printUsageAndExit(which);
                var builder = zosc.Message.Builder.init(allocator);
                defer builder.deinit();
                for (types, 5..) |tag, i| {
                    switch (tag) {
                        's' => try builder.append(.{ .s = args[i] }),
                        'i' => try builder.append(.{ .i = std.fmt.parseInt(i32, args[i], 10) catch try printUsageAndExit(which) }),
                        'f' => try builder.append(.{ .f = std.fmt.parseFloat(f32, args[i]) catch try printUsageAndExit(which) }),
                        else => try printUsageAndExit(which),
                    }
                }
                break :msg try builder.commit(allocator, args[3]);
            };
            defer msg.unref();
            std.log.debug("{s}", .{msg.toBytes()});
            _ = try std.posix.send(socket, msg.toBytes(), 0);
        },
    }
}

const Which = enum { send, dump };

fn printUsageAndExit(which: Which) !noreturn {
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();
    switch (which) {
        .send => try stdout.print(
            \\USAGE: zoscsend address port path [types [arg0 arg1 ...]]
            \\
            \\example: zoscsend 127.0.0.1 1111 /test/path sif "hello world!" -15 3.1415
            \\
        , .{}),
        .dump => try stdout.print(
            \\USAGE: zoscdump address port
            \\
            \\C-c to exit.
            \\
        , .{}),
    }
    try bw.flush();
    std.process.exit(1);
}
