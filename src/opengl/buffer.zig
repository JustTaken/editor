const std = @import("std");
const gl = @import("zgl");

const Change = struct {
    offset: u16,
    count: u16,
};

pub fn Buffer(comptime T: type) type {
    return struct {
        handle: gl.Buffer,
        array: std.ArrayList(T),
        kind: gl.BufferTarget,
        size: u32,

        const Self = @This();

        // pub const Indexer = struct {
        //     handle: gl.Buffer,
        //     indiceHandle: gl.Buffer,
        //     kind: gl.BufferTarget,

        //     indexSize: u32,
        //     indices: []u32,
        //     changes: [3]Change,
        //     changeCount: u32,
        //     clearConst: u32,

        //     const ByteSize: u32 = 8;

        //     pub fn pushIndex(self: *Indexer, offset: u32, index: u32) void {
        //         const coef = (@sizeOf(u32) / self.indexSize);
        //         const clearValue = self.clearConst << @as(u5, @intCast(self.indexSize * ByteSize * (offset % coef)));

        //         self.indices[offset / coef] &= ~clearValue;
        //         self.indices[offset / coef] |= index << @as(u5, @intCast(self.indexSize * ByteSize * (offset % coef)));
        //     }

        //     pub fn syncIndex(self: *Indexer, size: u32) bool {
        //         const alignSize = @sizeOf(u32) - (size % @sizeOf(u32)) + size;
        //         gl.namedBufferSubData(self.indiceHandle, 0, u32, self.indices[0..alignSize / (@sizeOf(u32) / self.indexSize)]);

        //         return true;
        //     }

        //     pub fn pushData(self: *Indexer, offset: u32, data: []const T) void {
        //         gl.namedBufferSubData(self.handle, offset * @sizeOf(T), T, data);
        //     }

        //     pub fn bind(self: *Indexer, mainDataLoc: u32, indexerDataLoc: u32) void {
        //         gl.bindBufferBase(self.kind, mainDataLoc, self.handle);
        //         gl.bindBufferBase(self.kind, indexerDataLoc, self.indiceHandle);
        //     }

        //     pub fn deinit(self: *const Indexer) void {
        //         self.handle.delete();
        //         self.indiceHandle.delete();
        //     }
        // };

        pub fn new(kind: gl.BufferTarget, size: u32, allocator: std.mem.Allocator) error{OutOfMemory}!Self {
            var self: Self = undefined;

            self.handle = gl.Buffer.create();
            self.kind = kind;
            self.array = try std.ArrayList(T).initCapacity(allocator, size);

            gl.namedBufferStorage(self.handle, T, size, null, .{ .dynamic_storage = true });

            return self;
        }

        // pub fn indexer(self: *const Self, size: u32, indexerType: type, allocator: std.mem.Allocator) error{OutOfMemory}!Indexer {
        //     var i: Indexer = undefined;

        //     i.handle = self.handle;
        //     i.kind = self.kind;
        //     i.indexSize = @sizeOf(indexerType);
        //     i.clearConst = std.math.maxInt(indexerType);

        //     i.indiceHandle = gl.Buffer.create();

        //     const alignSize = @sizeOf(u32) - (size % @sizeOf(u32)) + size;

        //     gl.namedBufferStorage(i.indiceHandle, u32, alignSize / (@sizeOf(u32) / i.indexSize), null, .{ .dynamic_storage = true });

        //     i.indices = try allocator.alloc(u32, alignSize / (@sizeOf(u32) / i.indexSize));

        //     @memset(i.indices, 0);

        //     return i;
        // }

        pub fn push(self: *const Self) void {
            gl.namedBufferSubData(self.handle, 0, T, self.array.items);
        }

        pub fn bind(self: *const Self, loc: u32) void {
            gl.bindBufferBase(self.kind, loc, self.handle);
        }

        pub fn deinit(self: *const Self) void {
            self.handle.delete();
        }
    };
}
