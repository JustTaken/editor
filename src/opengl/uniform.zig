const gl = @import("zgl");

pub fn Uniform(comptime T: type, comptime N: u32) type {
    return struct {
        data: [N]T,
        handle: gl.Buffer,
        loc: u32,

        const Self = @This();
        pub fn pushData(self: *Self, offset: u32, count: u32) void {
            gl.bindBuffer(self.handle, .uniform_buffer);
            gl.bufferSubData(.uniform_buffer, offset * @sizeOf(T), T, self.data[offset..offset + count]);
            gl.bindBuffer(gl.Buffer.invalid, .uniform_buffer);
        }

        pub fn init(self: *Self, data: [N]T, loc: u32) void {
            self.handle = gl.Buffer.gen();
            self.loc = loc;
            self.data = data;

            gl.bindBuffer(self.handle, .uniform_buffer);
            gl.bufferData(.uniform_buffer, T, &data, .dynamic_draw);
            gl.bindBufferBase(.uniform_buffer, self.loc, self.handle);
            gl.bindBuffer(gl.Buffer.invalid, .uniform_buffer);
        }

        pub fn deinit(self: *Self) void {
            self.handle.delete();
        }
    };
}
