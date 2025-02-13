const gl = @import("zgl");

pub fn Buffer(comptime T: type) type {
    return struct {
        handle: gl.Buffer,
        kind: gl.BufferTarget,
        count: u32,
        size: u32,

        const Self = @This();

        pub const Slice = struct {
            handle: gl.Buffer,
            kind: gl.BufferTarget,
            offset: u32,
            count: u32,

            pub fn pushData(self: *Slice, offset: u32, data: []const T) void {
                gl.namedBufferSubData(self.handle, offset * @sizeOf(T), T, data);
            }

            pub fn bind(self: *Slice, loc: u32) void {
                gl.bindBufferBase(self.kind, loc, self.handle);
            }
        };

        pub fn new(kind: gl.BufferTarget, size: u32, data: ?[]const T) Self {
            var self: Self = undefined;

            self.handle = gl.Buffer.create();
            self.kind = kind;
            self.size = size;
            self.count = 0;

            var ptr: ?[*]const T = null;
            if (data) |d| ptr = d.ptr;

            gl.namedBufferStorage(self.handle, T, size, ptr, .{ .dynamic_storage = true });

            return self;
        }

        pub fn getSlice(self: *Self, count: u32) error{OutOfMemory}!Slice {
            if (self.count + count > self.size) return error.OutOfMemory;
            defer self.size += count;

            return .{
                .handle = self.handle,
                .offset = self.count,
                .kind = self.kind,
                .count = count,
            };
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
