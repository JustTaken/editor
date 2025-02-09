const gl = @import("zgl");

pub fn Buffer(comptime T: type) type {
    return struct {
        handle: gl.Buffer,
        kind: gl.BufferTarget,

        const Self = @This();

        pub fn new(kind: gl.BufferTarget, size: u32, data: ?[]const T) Self {
            var self: Self = undefined;

            self.handle = gl.Buffer.create();
            self.kind = kind;

            var ptr: ?[*]const T = null;
            if (data) |d| ptr = d.ptr;

            gl.namedBufferStorage(self.handle, T, size, ptr, .{ .dynamic_storage = true });

            return self;
        }

        pub fn pushData(self: *const Self, offset: u32, data: []const T) void {
            gl.namedBufferSubData(self.handle, offset * @sizeOf(T), T, data);
        }

        pub fn bind(self: *const Self, loc: u32) void {
            gl.bindBufferBase(self.kind, loc, self.handle);
        }

        pub fn deinit(self: *const Self) void {
            self.handle.delete();
        }
    };
}
