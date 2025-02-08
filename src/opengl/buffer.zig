const gl = @import("zgl");

pub fn Buffer(comptime T: type, comptime N: u32) type {
    return struct {
        data: [N]T,
        handle: gl.Buffer,
        kind: gl.BufferTarget,

        const Self = @This();

        pub fn new(kind: gl.BufferTarget, usage: gl.BufferUsage, data: [N]T) Self {
            var self: Self = undefined;
            self.handle = gl.Buffer.gen();
            self.data = data;
            self.kind = kind;

            gl.bindBuffer(self.handle, kind);
            gl.bufferData(kind, T, &data, usage);
            gl.bindBuffer(gl.Buffer.invalid, kind);

            return self;
        }

        pub fn pushData(self: *const Self, offset: u32, count: u32) void {
            gl.bindBuffer(self.handle, self.kind);
            gl.bufferSubData(self.kind, offset * @sizeOf(T), T, self.data[offset..offset + count]);
            gl.bindBuffer(gl.Buffer.invalid, self.kind);
        }

        pub fn bind(self: *const Self, loc: u32) void {
            gl.bindBufferBase(self.kind, loc, self.handle);
        }

        pub fn deinit(self: *const Self) void {
            self.handle.delete();
        }
    };
}
