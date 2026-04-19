const zosc = @import("zosc");
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);

    const io = init.io;

    const which: Which = if (std.mem.endsWith(u8, args[0], "zoscdump")) .dump else .send;
    if (args.len < 3) try printUsageAndExit(io, which);

    const port = std.fmt.parseInt(u16, args[2], 10) catch {
        try printUsageAndExit(io, which);
    };
    const addr: std.Io.net.IpAddress = .{
        .ip4 = std.Io.net.Ip4Address.parse(args[1], port) catch |err| {
            std.log.err("error parsing IP address: {s}", .{@errorName(err)});
            try printUsageAndExit(io, which);
        },
    };
    // try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
    // try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

    switch (which) {
        .dump => {
            const buffer = try allocator.alloc(u8, 0xffff);
            defer allocator.free(buffer);

            const stdout_file = std.Io.File.stdout();
            var buf: [2048]u8 = undefined;
            var writer = stdout_file.writer(io, &buf);
            const stdout = &writer.interface;

            const socket = try addr.bind(io, .{
                .mode = .dgram,
                .protocol = .udp,
                .allow_broadcast = true,
            });
            defer socket.close(io);

            while (true) {
                const sock_msg = try socket.receive(io, buffer);
                const msg = zosc.Message.fromBytes(allocator, sock_msg.data) catch {
                    std.log.err("error while parsing message:\n{s}", .{sock_msg.data});
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
                        try stdout.print("{f}\n", .{arg});
                    }
                }
                try writer.flush();
            }
        },
        .send => {
            const socket = try addr.connect(io, .{ .mode = .dgram, .protocol = .udp, .timeout = .none });
            if (args.len < 4) try printUsageAndExit(io, which);
            const msg: *zosc.Message = if (args.len == 4)
                try zosc.Message.fromTuple(allocator, args[3], .{})
            else msg: {
                const types = args[4];
                if (args.len < 5 + types.len) try printUsageAndExit(io, which);
                var builder: zosc.Message.Builder = .init;
                defer builder.deinit(allocator);
                for (types, 5..) |tag, i| {
                    switch (tag) {
                        's' => try builder.append(allocator, .{ .s = args[i] }),
                        'i' => try builder.append(allocator, .{ .i = std.fmt.parseInt(i32, args[i], 10) catch try printUsageAndExit(io, which) }),
                        'f' => try builder.append(allocator, .{ .f = std.fmt.parseFloat(f32, args[i]) catch try printUsageAndExit(io, which) }),
                        else => try printUsageAndExit(io, which),
                    }
                }
                break :msg try builder.commit(allocator, args[3]);
            };
            defer msg.unref();
            std.log.debug("{s}", .{msg.toBytes()});
            var w = socket.writer(io, &.{});
            try w.interface.writeAll(msg.toBytes());
            try w.interface.flush();
            socket.close(io);
        },
    }
}

const Which = enum { send, dump };

fn printUsageAndExit(io: std.Io, which: Which) !noreturn {
    const stdout_file = std.Io.File.stdout();
    var buf: [2048]u8 = undefined;
    var writer = stdout_file.writer(io, &buf);
    const stdout = &writer.interface;
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
    try writer.flush();
    std.process.exit(1);
}
