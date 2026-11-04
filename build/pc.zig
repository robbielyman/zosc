const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    std.debug.assert(args.len == 2);
    const file = std.Io.File.stdout();
    var buf: [1024]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.print(
        \\prefix={s}
        \\includedir=${{prefix}}/include
        \\libdir=${{prefix}}/lib
        \\
        \\Name: zosc
        \\URL: https://github.com/robbielyman/zosc
        \\Description: Zig-powered implementation of OSC messaging and servers
        \\Version: 0.1.0
        \\Cflags: -I${{includedir}}
        \\Libs: -L${{libdir}} -lzosc
    , .{args[1]});
    try w.flush();
}
