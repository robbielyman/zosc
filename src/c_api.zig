const std = @import("std");
const zosc = @import("zosc");

// BUNDLE PARSING

pub const zosc_bundle_iterator_t = opaque {};

export fn zosc_bundle_iterator_create() ?*zosc_bundle_iterator_t {
    const ptr = std.heap.c_allocator.create(zosc.Parse.BundleIterator) catch return null;
    return @ptrCast(ptr);
}

export fn zosc_bundle_iterator_destroy(ptr: ?*zosc_bundle_iterator_t) void {
    const iter: *zosc.Parse.BundleIterator = @ptrCast(@alignCast(ptr orelse return));
    std.heap.c_allocator.destroy(iter);
}

export fn zosc_bundle_iterator_init(self: ?*zosc_bundle_iterator_t, ptr: ?[*]const u8, len: usize) bool {
    const iter: *zosc.Parse.BundleIterator = @ptrCast(@alignCast(self orelse return false));
    const slice = (ptr orelse return false)[0..len];
    iter.* = switch (zosc.parseOSC(slice) catch return false) {
        .bundle => |b| b,
        .message => return false,
    };
    return true;
}

export fn zosc_bundle_iterator_next(self: ?*zosc_bundle_iterator_t, len: ?*usize) ?[*]const u8 {
    const iter: *zosc.Parse.BundleIterator = @ptrCast(@alignCast(self orelse return null));
    const slice = (iter.next() catch return null) orelse return null;
    if (len) |len_ptr| len_ptr.* = slice.len;
    return slice.ptr;
}

export fn zosc_bundle_iterator_reset(self: ?*zosc_bundle_iterator_t) void {
    const iter: *zosc.Parse.BundleIterator = @ptrCast(@alignCast(self orelse return));
    iter.reset();
}

// MESSAGE PARSING

pub const zosc_message_iterator_t = opaque {};

export fn zosc_message_iterator_create() ?*zosc_message_iterator_t {
    const ptr = std.heap.c_allocator.create(zosc.Parse.MessageIterator) catch return null;
    return @ptrCast(ptr);
}

export fn zosc_message_iterator_destroy(ptr: ?*zosc_message_iterator_t) void {
    const iter: *zosc.Parse.MessageIterator = @ptrCast(@alignCast(ptr orelse return));
    std.heap.c_allocator.destroy(iter);
}

export fn zosc_message_iterator_init(self: ?*zosc_message_iterator_t, ptr: ?[*]const u8, len: usize) bool {
    const iter: *zosc.Parse.MessageIterator = @ptrCast(@alignCast(self orelse return false));
    const slice = (ptr orelse return false)[0..len];
    iter.* = switch (zosc.parseOSC(slice) catch return false) {
        .bundle => return false,
        .message => |m| m,
    };
    return true;
}

export fn zosc_message_iterator_next(self: ?*zosc_message_iterator_t, data: ?*zosc_data_t, data_type: ?*u8) i32 {
    const iter: *zosc.Parse.MessageIterator = @ptrCast(@alignCast(self orelse return -1));
    const d = data orelse return -1;
    const datum = iter.next() catch return -1;
    d.* = switch (datum orelse return 0) {
        inline .s, .S, .b => |bytes, tag| @unionInit(zosc_data_t, @tagName(tag), .{ .ptr = bytes.ptr, .len = bytes.len }),
        inline else => |item, tag| @unionInit(zosc_data_t, @tagName(tag), item),
    };
    if (data_type) |@"type"| @"type".* = switch (datum.?) {
        inline else => |_, tag| @tagName(tag)[0],
    };
    return 1;
}

export fn zosc_message_iterator_reset(self: ?*zosc_message_iterator_t) void {
    const iter: *zosc.Parse.MessageIterator = @ptrCast(@alignCast(self orelse return));
    iter.reset();
}

// DATA

pub const zosc_bytes_t = extern struct {
    ptr: [*]const u8,
    len: usize,
};

pub const zosc_timetag_t = zosc.TimeTag;

export fn zosc_timetag_from_nano_timestamp(nanoseconds: i128) zosc.TimeTag {
    return zosc.TimeTag.fromNanoTimestamp(nanoseconds).t;
}

export fn zosc_timetag_from_timestamp(seconds: i64) zosc.TimeTag {
    return zosc.TimeTag.fromTimestamp(seconds).t;
}

pub const zosc_data_t = extern union {
    i: i32,
    f: f32,
    s: zosc_bytes_t,
    S: zosc_bytes_t,
    b: zosc_bytes_t,
    t: zosc.TimeTag,
    d: f64,
    h: i64,
    c: u8,
    m: [4]u8,
    N: void,
    I: void,
    T: void,
    F: void,
    r: u32,
};

// MESSAGES

pub const zosc_message_t = opaque {};

export fn zosc_message_get_path(self: ?*zosc_message_t, len: ?*usize) ?[*]const u8 {
    const message: *zosc.Message = @ptrCast(@alignCast(self orelse return null));
    if (len) |l| l.* = message.path.len;
    return message.path.ptr;
}

export fn zosc_message_get_types(self: ?*zosc_message_t, len: ?*usize) ?[*]const u8 {
    const message: *zosc.Message = @ptrCast(@alignCast(self orelse return null));
    if (len) |l| l.* = message.types.len;
    return message.types.ptr;
}

export fn zosc_message_ref(self: ?*zosc_message_t) void {
    const message: *zosc.Message = @ptrCast(@alignCast(self orelse return));
    return message.ref();
}

export fn zosc_message_unref(self: ?*zosc_message_t) void {
    const message: *zosc.Message = @ptrCast(@alignCast(self orelse return));
    return message.unref();
}

export fn zosc_message_to_bytes(self: ?*zosc_message_t, len: ?*usize) ?[*]const u8 {
    const message: *zosc.Message = @ptrCast(@alignCast(self orelse return null));
    const slice = message.toBytes();
    if (len) |l| l.* = slice.len;
    return slice.ptr;
}

export fn zosc_message_from_bytes(ptr: ?[*]const u8, len: usize) ?*zosc_message_t {
    const slice = (ptr orelse return null)[0..len];
    return @ptrCast(zosc.Message.fromBytes(std.heap.c_allocator, slice) catch null);
}

export fn zosc_message_clone(self: ?*zosc_message_t) ?*zosc_message_t {
    const message: *zosc.Message = @ptrCast(@alignCast(self orelse return null));
    return @ptrCast(message.clone(std.heap.c_allocator) catch return null);
}

export fn zosc_message_build(path_ptr: ?[*]const u8, path_len: usize, types_ptr: ?[*]const u8, types_len: usize, data_ptr: ?[*]const u8, data_len: usize) ?*zosc_message_t {
    return @ptrCast(zosc.Message.build(
        std.heap.c_allocator,
        (path_ptr orelse return null)[0..path_len],
        (types_ptr orelse return null)[0..types_len],
        (data_ptr orelse return null)[0..data_len],
    ) catch return null);
}

// BUILDING

pub const zosc_message_builder_t = opaque {};

export fn zosc_message_builder_create() ?*zosc_message_builder_t {
    const self = std.heap.c_allocator.create(zosc.Message.Builder) catch return null;
    self.* = zosc.Message.Builder.init(std.heap.c_allocator);
    return @ptrCast(self);
}

export fn zosc_message_builder_destroy(self: ?*zosc_message_builder_t) void {
    const builder: *zosc.Message.Builder = @ptrCast(@alignCast(self orelse return));
    builder.deinit();
    std.heap.c_allocator.destroy(builder);
}

export fn zosc_message_builder_commit(self: ?*const zosc_message_builder_t, path_ptr: ?[*]const u8, len: usize) ?*zosc_message_t {
    const builder: *const zosc.Message.Builder = @ptrCast(@alignCast(self orelse return null));
    const path = (path_ptr orelse return null)[0..len];
    return @ptrCast(builder.commit(std.heap.c_allocator, path) catch return null);
}

export fn zosc_message_builder_append(self: ?*zosc_message_builder_t, data: zosc_data_t, tag: u8) bool {
    const builder: *zosc.Message.Builder = @ptrCast(@alignCast(self orelse return false));
    switch (tag) {
        inline 'i', 'f', 't', 'T', 'F', 'N', 'I', 'r', 'h', 'd' => |which| {
            builder.append(@unionInit(zosc.Data, &.{which}, @field(data, &.{which}))) catch return false;
            return true;
        },
        inline 's', 'S', 'b' => |which| {
            const slice = @field(data, &.{which}).ptr[0..@field(data, &.{which}).len];
            builder.append(@unionInit(zosc.Data, &.{which}, slice)) catch return false;
            return true;
        },
        else => return false,
    }
}

// BUNDLES

pub const zosc_bundle_t = opaque {};

export fn zosc_bundle_get_timetag(self: ?*zosc_bundle_t) zosc_timetag_t {
    const bundle: *zosc.Bundle = @ptrCast(@alignCast(self orelse return .{
        .seconds = 0,
        .frac = 0,
    }));
    return bundle.time;
}

export fn zosc_bundle_ref(self: ?*zosc_bundle_t) void {
    const bundle: *zosc.Bundle = @ptrCast(@alignCast(self orelse return));
    return bundle.ref();
}

export fn zosc_bundle_unref(self: ?*zosc_bundle_t) void {
    const bundle: *zosc.Bundle = @ptrCast(@alignCast(self orelse return));
    return bundle.unref();
}

export fn zosc_bundle_to_bytes(self: ?*zosc_bundle_t, len: ?*usize) ?[*]const u8 {
    const bundle: *zosc.Bundle = @ptrCast(@alignCast(self orelse return null));
    const slice = bundle.toBytes();
    if (len) |l| l.* = slice.len;
    return slice.ptr;
}

export fn zosc_bundle_from_bytes(ptr: ?[*]const u8, len: usize) ?*zosc_bundle_t {
    const slice = (ptr orelse return null)[0..len];
    return @ptrCast(zosc.Bundle.fromBytes(std.heap.c_allocator, slice) catch null);
}

export fn zosc_bundle_build(tag: zosc_timetag_t, content_ptr: ?[*]const u8, content_len: usize) ?*zosc_message_t {
    return @ptrCast(zosc.Bundle.build(
        std.heap.c_allocator,
        tag,
        (content_ptr orelse return null)[0..content_len],
    ) catch return null);
}

// BUILDING

pub const zosc_bundle_builder_t = opaque {};

export fn zosc_bundle_builder_create() ?*zosc_bundle_builder_t {
    const self = std.heap.c_allocator.create(zosc.Bundle.Builder) catch return null;
    self.* = zosc.Bundle.Builder.init(std.heap.c_allocator);
    return @ptrCast(self);
}

export fn zosc_bundle_builder_destroy(self: ?*zosc_bundle_builder_t) void {
    const builder: *zosc.Bundle.Builder = @ptrCast(@alignCast(self orelse return));
    builder.deinit();
    std.heap.c_allocator.destroy(builder);
}

export fn zosc_bundle_builder_commit(self: ?*const zosc_bundle_builder_t, time: zosc_timetag_t) ?*zosc_bundle_t {
    const builder: *const zosc.Bundle.Builder = @ptrCast(@alignCast(self orelse return null));
    return @ptrCast(builder.commit(std.heap.c_allocator, time) catch return null);
}

export fn zosc_bundle_builder_append(self: ?*zosc_bundle_builder_t, message: ?*const zosc_message_t) bool {
    const builder: *zosc.Bundle.Builder = @ptrCast(@alignCast(self orelse return false));
    const msg: *const zosc.Message = @ptrCast(@alignCast(message orelse return false));
    builder.append(msg) catch return false;
    return true;
}

// METHODS

export fn zosc_match_path(pattern_ptr: ?[*]const u8, pattern_len: usize, path_ptr: ?[*]const u8, path_len: usize) bool {
    return zosc.matchPath((pattern_ptr orelse return false)[0..pattern_len], (path_ptr orelse return false)[0..path_len]);
}

export fn zosc_match_types(pattern_ptr: ?[*]const u8, pattern_len: usize, types_ptr: ?[*]const u8, types_len: usize) bool {
    return zosc.matchPath((pattern_ptr orelse return false)[0..pattern_len], (types_ptr orelse return false)[0..types_len]);
}
