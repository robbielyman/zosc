pub fn RefCount(
    comptime T: type,
    comptime field_name: []const u8,
    comptime deinitFn: fn (this: *T, allocator: std.mem.Allocator) void,
) type {
    return struct {
        allocator: std.mem.Allocator,
        ref_count: usize,

        const Self = @This();

        pub fn ref(self: *Self) void {
            self.ref_count += 1;
        }

        pub fn unref(self: *Self) void {
            std.debug.assert(self.ref_count > 0);
            self.ref_count -= 1;
            if (self.ref_count > 0) return;
            const parent: *T = @fieldParentPtr(field_name, self);
            @call(.always_inline, deinitFn, .{ parent, self.allocator });
        }
    };
}

const std = @import("std");
