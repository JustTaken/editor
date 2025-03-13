const std = @import("std");

const Allocator = std.mem.Allocator;
const List = std.DoublyLinkedList;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const ArrayList = std.ArrayList;
const Map = std.AutoArrayHashMap;

const Matrix = @import("math.zig").Matrix;
const Buffer = @import("opengl/buffer.zig").Buffer;
const FreeType = @import("font.zig").FreeType;
const Texture = @import("opengl/texture.zig").Texture;

const IDENTITY = Matrix(4).identity();

pub const RangeIter = struct {
    line: ?*LineNode,

    cursor: Cursor,

    currentYOffset: u32,

    startYOffset: u32,
    startXOffset: u32,

    xPosOffset: i32,
    yPosOffset: i32,
    zPosOffset: i32,

    width: u32,
    height: u32,

    cursorTransform: Matrix(4),
    generator: *GlyphGenerator,

    fn new(
        width: u32,
        height: u32,
        prevXOffset: *u32,
        prevYOffset: *u32,
        xPosOffset: i32,
        yPosOffset: i32,
        zPosOffset: i32,
        cursor: Cursor,
        currentLine: *LineNode,
        generator: *GlyphGenerator,
    ) ?RangeIter {
        const yPosRange = cursor.y * generator.font.height;
        var yOffset = prevYOffset.*;

        while (yOffset + height < yPosRange + generator.font.height) {
            yOffset += generator.font.height;
        }

        while (yOffset > yPosRange) {
            yOffset -= generator.font.height;
        }

        var colCount: u32 = 0;
        var xPosRange: u32 = 0;

        var currentBuffer: ?*BufferNode = currentLine.data.buffer.first;
        outer: while (currentBuffer) |b| {
            for (b.data.handle[0..b.data.len]) |c| {
                if (colCount >= cursor.x) break :outer;

                const info = generator.get(c) catch return null;

                xPosRange += info.advance;
                colCount += 1;
            }

            currentBuffer = b.next;
        }

        currentBuffer = currentLine.data.buffer.first;
        var xOffset: u32 = prevXOffset.*;

        if (xOffset > xPosRange) {
            xOffset = xPosRange;
        }

        outer: while (currentBuffer) |b| {
            for (b.data.handle[0..b.data.len]) |c| {
                if (xOffset + width > xPosRange) break :outer;

                const info = generator.get(c) catch return null;
                xOffset += info.advance;
            }

            currentBuffer = b.next;
        }

        var line = currentLine;
        var lineIndex = cursor.y;
        const lineIndexStart = yOffset / generator.font.height;

        while (lineIndex > lineIndexStart) {
            line = line.prev orelse return null;
            lineIndex -= 1;
        }

        const cursorTransform = IDENTITY.translate(.{@floatFromInt(@as(i32, @intCast(xPosRange - xOffset)) + xPosOffset), @as(f32, @floatFromInt(-@as(i32, @intCast(yPosRange - yOffset)) + yPosOffset)), @floatFromInt(zPosOffset)});

        prevYOffset.* = yOffset;
        prevXOffset.* = xOffset;

        return .{
            .width = width,
            .height = height,
            .line = line,
            .cursor = cursor,
            .currentYOffset = yOffset,
            .startYOffset = yOffset,
            .startXOffset = xOffset,
            .xPosOffset = xPosOffset,
            .yPosOffset = yPosOffset,
            .zPosOffset = zPosOffset,
            .cursorTransform = cursorTransform,
            .generator = generator,
        };
    }

    pub fn nextLine(self: *RangeIter, infos: []CharInfo) ?[]CharInfo {
        if (self.currentYOffset >= self.height + self.startYOffset) return null;

        const line = self.line orelse return null;

        defer self.line = line.next;
        defer self.currentYOffset += self.generator.font.height;

        const y = @as(i32, @intCast(self.currentYOffset)) - @as(i32, @intCast(self.startYOffset));

        var currentBuffer: ?*BufferNode = line.data.buffer.first;
        var xOffset: i32 = 0;
        var len: u32 = 0;

        outer: while (currentBuffer) |b| {
            for (b.data.handle[0..b.data.len]) |c| {
                if (xOffset >= self.width + self.startXOffset) break :outer;

                var info = self.generator.get(c) catch return null;

                const x = @as(i32, @intCast(xOffset)) - @as(i32, @intCast(self.startXOffset));

                info.transform = info.transform.translate(.{@floatFromInt(x + self.xPosOffset), @floatFromInt(-y + self.yPosOffset), @floatFromInt(self.zPosOffset)});
                xOffset += @intCast(info.advance);

                infos[len] = info;

                len += @intFromBool(xOffset >= self.startXOffset);
            }

            currentBuffer = b.next;
        }

        return infos[0..len];
    }
};

const LineBuffer = struct {
    handle: [*]u8,
    len: u16,
    capacity: u16,

    fn init(self: *LineBuffer, allocator: Allocator, size: u32) error{OutOfMemory}!void {
        const handle = try allocator.alloc(u8, size);

        self.handle = handle.ptr;
        self.capacity = @intCast(handle.len);
        self.len = 0;
    }

    pub fn fromBytes(self: *LineBuffer, bytes: []u8) void {
        self.handle = bytes.ptr;
        self.capacity = @intCast(bytes.len);
        self.len = self.capacity;
    }
};

const Line = struct {
    buffer: List(LineBuffer),

    pub fn write(self: *Line, out: []u8) u32 {
        var buffer = self.buffer.first;

        var count: u32 = 0;
        while (buffer) |b| {
            std.mem.copyForwards(u8, out[count..], b.data.handle[0..b.data.len]);
            buffer = b.next;
            count += b.data.len;
        }

        return count;
    }


    fn print(self: *Line) void {
        var buffer = self.buffer.first;

        var count: u32 = 0;
        while (buffer) |b| {
            std.debug.print(" {d:0>3} -> [{s}]\n", .{ count, b.data.handle[0..b.data.len] });
            buffer = b.next;
            count += 1;
        }
    }
};

const LineNode = List(Line).Node;
const BufferNode = List(LineBuffer).Node;
const MIN_BUFFER_SIZE: u32 = 30;

pub const FreePool = struct {
    buffers: List(LineBuffer),
    lines: List(Line),

    allocator: *FixedBufferAllocator,

    pub fn new(allocator: *FixedBufferAllocator) FreePool {
        return .{
            .buffers = .{},
            .lines = .{},
            .allocator = allocator,
        };
    }

    pub fn bufferFromFile(self: *FreePool, path: []const u8) error{OutOfMemory, CannotHandleThisBig, NotFound}!List(LineBuffer) {
        const allocator = self.allocator.allocator();

        const content = std.fs.cwd().readFileAlloc(allocator, path, 16 * std.mem.page_size) catch |e| {
            switch (e) {
                error.FileTooBig => return error.CannotHandleThisBig,
                error.FileNotFound => return error.NotFound,
                else => return error.OutOfMemory,
            }
        };

        var list = List(LineBuffer) {};

        var start: u16 = 0;
        for (content, 0..) |c, i| {
            if (c == '\n') {
                const currentBuffer = try allocator.create(BufferNode);
                currentBuffer.data.fromBytes(content[start..i]);

                list.append(currentBuffer);
                start = @intCast(i + 1);
            }
        }

        if (start != content.len) {
            const currentBuffer = try allocator.create(BufferNode);

            currentBuffer.data.fromBytes(content[start..]);
            list.append(currentBuffer);
        }

        return list;
    }

    fn newLine(self: *FreePool) error{OutOfMemory}!*LineNode {
        if (self.lines.pop()) |line| {
            line.data.buffer = .{};

            return line;
        }

        const line = self.allocator.allocator().create(LineNode) catch {
            std.log.err("failed to create line Node, usage: {}, total: {}", .{self.allocator.end_index, self.allocator.buffer.len});
            return error.OutOfMemory;
        };

        line.data.buffer = .{};

        return line;
    }

    fn newBuffer(self: *FreePool) error{OutOfMemory}!*BufferNode {
        if (self.buffers.pop()) |buffer| {
            return buffer;
        }

        const allocator = self.allocator.allocator();
        const buffer = try allocator.create(BufferNode);

        try buffer.data.init(allocator, MIN_BUFFER_SIZE);

        return buffer;
    }

    fn freeLine(self: *FreePool, line: *LineNode) void {
        while (line.data.buffer.pop()) |buffer| {
            self.freeBuffer(buffer);
        }

        self.lines.append(line);
    }

    fn freeBuffer(self: *FreePool, buffer: *BufferNode) void {
        buffer.data.len = 0;
        self.buffers.append(buffer);
    }
};

pub const Lines = struct {
    cursor: Cursor,
    selection: ?Cursor,

    yOffset: u32,
    xOffset: u32,

    lines: List(Line),

    change: bool,

    currentLine: *LineNode,
    currentBuffer: *BufferNode,

    freePool: *FreePool,
    name: [100]u8,
    nameLen: usize,

    const BufferNodeWithOffset = struct {
        offset: u32,
        buffer: *BufferNode,
    };

    const DefaultName = "scratch";

    pub fn init(self: *Lines, freePool: *FreePool) error{OutOfMemory}!void {
        self.reset();
        self.freePool = freePool;

        self.currentLine = try self.freePool.newLine();
        self.currentBuffer = try self.freePool.newBuffer();
        self.currentLine.data.buffer.append(self.currentBuffer);

        self.lines = .{};
        self.lines.append(self.currentLine);

        for (DefaultName, 0..) |n, i| {
            self.name[i] = n;
        }

        self.nameLen = DefaultName.len;
    }

    pub fn fromFile(self: *Lines, freePool: *FreePool, path: []const u8) error{OutOfMemory, CannotHandleThisBig, NotFound}!void {
        self.reset();
        self.freePool = freePool;

        const buffers = self.freePool.bufferFromFile(path) catch return error.CannotHandleThisBig;

        var currentBuffer = buffers.first;
        while (currentBuffer) |buffer| {
            currentBuffer = buffer.next;

            const line = try self.freePool.newLine();

            line.data.buffer.append(buffer);
            self.lines.append(line);
        }

        self.currentLine = self.lines.first.?;
        self.currentBuffer = self.currentLine.data.buffer.first.?;

        for (path, 0..) |n, i| {
            self.name[i] = n;
        }

        self.nameLen = path.len;
    }

    pub fn save(self: *Lines) error{Write, NotFound, OutOfMemory}!void {
        var line = self.lines.first;

        var allocator = FixedBufferAllocator.init(try self.freePool.allocator.allocator().alloc(u8, std.mem.page_size));
        const alloc = allocator.allocator();
        var content = try ArrayList(u8).initCapacity(alloc, 1024);
        defer content.clearAndFree();

        while (line) |l| {
            var buffer = l.data.buffer.first;

            while (buffer) |b| {
                try content.appendSlice(b.data.handle[0..b.data.len]);
                buffer = b.next;
            }

            try content.append('\n');

            line = l.next;
        }

        const file = std.fs.cwd().createFile(self.name[0..self.nameLen], .{}) catch return error.NotFound;
        file.writeAll(content.items) catch return error.Write;
    }

    fn reset(self: *Lines) void {
        self.cursor.x = 0;
        self.cursor.y = 0;
        self.cursor.offset = 0;
        self.xOffset = 0;
        self.yOffset = 0;
        self.change = true;
        self.selection = null;
        self.lines = .{};
    }

    pub fn moveLineDown(self: *Lines, count: u32) void {
        defer self.change = true;
        var c = count;

        while (self.currentLine.next) |l| {
            if (c == 0) break;

            self.currentLine = l;

            self.cursor.y += 1;
            c -= 1;
        }

        const xCount = self.cursor.x;
        self.cursor.x = 0;
        self.cursor.offset = 0;
        self.currentBuffer = self.currentLine.data.buffer.first.?;
        self.moveFoward(xCount);
    }

    pub fn moveLineUp(self: *Lines, count: u32) void {
        defer self.change = true;

        var c = count;

        while (self.currentLine.prev) |l| {
            if (c == 0) break;

            self.currentLine = l;

            self.cursor.y -= 1;
            c -= 1;
        }

        const xCount = self.cursor.x;
        self.cursor.x = 0;
        self.cursor.offset = 0;
        self.currentBuffer = self.currentLine.data.buffer.first.?;
        self.moveFoward(xCount);
    }

    pub fn moveFoward(self: *Lines, count: u32) void {
        defer self.change = true;

        const bufferWithOffset = self.moveFowardBufferNode(self.currentLine, self.currentBuffer, self.cursor.offset, count);

        self.currentBuffer = bufferWithOffset.buffer;
        self.cursor.offset = bufferWithOffset.offset;
    }

    fn moveFowardBufferNode(self: *Lines, line: *LineNode, buffer: *BufferNode, offset: u32, count: u32) BufferNodeWithOffset {
        if (count + offset > buffer.data.len) {
            self.cursor.x += @intCast(buffer.data.len - offset);

            if (buffer.next) |next| {
                std.debug.assert(buffer.data.len == buffer.data.capacity);
                return self.moveFowardBufferNode(line, next, 0, count - (buffer.data.len - offset));
            }

            return .{
                .offset = @intCast(buffer.data.len),
                .buffer = buffer,
            };
        }

        self.cursor.x += count;

        return .{
            .offset = offset + count,
            .buffer = buffer,
        };
    }

    pub fn moveBack(self: *Lines, count: u32) void {
        defer self.change = true;

        const bufferWithOffset = self.moveBackBufferNode(self.currentLine, self.currentBuffer, self.cursor.offset, count);

        self.currentBuffer = bufferWithOffset.buffer;
        self.cursor.offset = bufferWithOffset.offset;
    }

    fn moveBackBufferNode(self: *Lines, line: *LineNode, buffer: *BufferNode, offset: u32, count: u32) BufferNodeWithOffset {
        if (count > offset) {
            self.cursor.x -= offset;

            if (buffer.prev) |prev| {
                std.debug.assert(prev.data.len == prev.data.capacity);

                return self.moveBackBufferNode(line, prev, prev.data.len, count - offset);
            }

            return .{
                .offset = 0,
                .buffer = buffer,
            };
        }

        self.cursor.x -= count;

        return .{
            .offset = offset - count,
            .buffer = buffer,
        };
    }

    pub fn insertChar(self: *Lines, char: u8) error{OutOfMemory}!void {
        try self.insertString(&.{char});
    }

    pub fn insertString(self: *Lines, chars: []const u8) error{OutOfMemory}!void {
        defer self.change = true;

        var count: u32 = 0;
        for (chars, 0..) |c, i| {
            if (c == '\n') {
                _ = try self.insertBufferNodeChars(self.currentLine, self.currentBuffer, self.cursor.offset, chars[count..i]);

                self.currentLine = try self.freePool.newLine();
                self.currentBuffer = try self.freePool.newBuffer();
                self.cursor.offset = 0;
                self.cursor.x = 0;

                count = @intCast(i + 1);
            }
        }

        if (count == chars.len) return;

        const bufferWithOffset = try self.insertBufferNodeChars(self.currentLine, self.currentBuffer, self.cursor.offset, chars[count..]);

        self.cursor.offset = bufferWithOffset.offset;
        self.currentBuffer = bufferWithOffset.buffer;
        self.cursor.x += @intCast(chars.len);
    }

    pub fn deleteForward(self: *Lines, count: u32) void {
        defer self.change = true;

        self.deleteBufferNodeCount(self.currentLine, self.currentBuffer, self.cursor.offset, count) catch {
            std.log.err("Failed to delete {} chars", .{count});
        };
    }

    fn nextBufferOrJoin(self: *Lines, line: *LineNode, buffer: *BufferNode, count: *u32) ?*BufferNode {
        if (buffer.next) |_| {} else {
            if (line.next) |l| {
                while (l.data.buffer.pop()) |buf| {
                    line.data.buffer.insertAfter(buffer, buf);
                }

                self.lines.remove(l);
                self.freePool.freeLine(l);

                count.* -= 1;
            }
        }

        return buffer.next;
    }

    fn nextBuffer(_: *Lines, _: *LineNode, buffer: *BufferNode, _: *u32) ?*BufferNode {
        return buffer.next;
    }

    fn deleteBufferNodeCount(self: *Lines, line: *LineNode, buffer: *BufferNode, offset: u32, count: u32) error{OutOfMemory}!void {
        if (count >= buffer.data.len - offset) {
            var current = buffer;

            if (offset == 0 and count == buffer.data.len) {
                if (buffer != self.currentBuffer) {
                    try self.removeBufferNode(line, buffer);
                }

                buffer.data.len = 0;

                return;
            }

            const f: *const fn (*Lines, *LineNode, *BufferNode, *u32) ?*BufferNode = if (count > current.data.len - offset) nextBufferOrJoin else nextBuffer;

            var c = count - (current.data.len - offset);
            var next = f(self, line, current, &c);

            while (next) |n| {
                if (n.data.len >= c) break;
                c -= @intCast(n.data.len);

                next = f(self, line, n, &c);
                try self.removeBufferNode(line, n);
            }

            if (next) |n| {
                const nextCount = min(current.data.capacity - offset, n.data.len - c);

                defer current.data.len = @intCast(offset + nextCount);
                std.mem.copyForwards(u8, current.data.handle[offset .. offset + nextCount], n.data.handle[c .. c + nextCount]);

                try self.deleteBufferNodeCount(line, n, 0, @intCast(c + nextCount));
            } else {
                current.data.len = @intCast(offset);
            }
        } else {
            std.mem.copyForwards(u8, buffer.data.handle[offset .. buffer.data.len - count], buffer.data.handle[offset + count .. buffer.data.len]);

            if (buffer.data.len == buffer.data.capacity) {
                try self.deleteBufferNodeCount(line, buffer, buffer.data.len - count, count);
            } else {
                buffer.data.len -= @intCast(count);
            }
        }
    }

    fn insertBufferNodeChars(self: *Lines, line: *LineNode, buffer: *BufferNode, offset: u32, chars: []const u8) error{OutOfMemory}!BufferNodeWithOffset {
        if (offset > buffer.data.len) return error.OutOfMemory;
        if (chars.len == 0) return .{
            .buffer = buffer,
            .offset = 0,
        };

        if (chars.len + offset > buffer.data.capacity) {
            defer buffer.data.len = buffer.data.capacity;

            try self.checkBufferNodeNext(line, buffer);
            _ = try self.insertBufferNodeChars(line, buffer.next.?, 0, buffer.data.handle[offset..buffer.data.len]);

            std.mem.copyForwards(u8, buffer.data.handle[offset..buffer.data.capacity], chars[0 .. buffer.data.capacity - offset]);
            return try self.insertBufferNodeChars(line, buffer.next.?, 0, chars[buffer.data.capacity - offset ..]);
        } else if (chars.len + buffer.data.len > buffer.data.capacity) {
            defer buffer.data.len = buffer.data.capacity;

            try self.checkBufferNodeNext(line, buffer);

            _ = try self.insertBufferNodeChars(line, buffer.next.?, 0, buffer.data.handle[buffer.data.capacity - chars.len .. buffer.data.len]);

            std.mem.copyBackwards(u8, buffer.data.handle[offset + chars.len .. buffer.data.capacity], buffer.data.handle[offset .. buffer.data.capacity - chars.len]);
        } else {
            defer buffer.data.len += @intCast(chars.len);

            std.mem.copyBackwards(u8, buffer.data.handle[offset + chars.len .. chars.len + buffer.data.len], buffer.data.handle[offset..buffer.data.len]);
        }

        std.mem.copyForwards(u8, buffer.data.handle[offset .. offset + chars.len], chars);

        return .{
            .buffer = buffer,
            .offset = @intCast(offset + chars.len),
        };
    }

    fn removeBufferNode(self: *Lines, line: *LineNode, buffer: *BufferNode) error{OutOfMemory}!void {
        line.data.buffer.remove(buffer);
        self.freePool.freeBuffer(buffer);

        if (line.data.buffer.last) |_| {
        } else {
            line.data.buffer.append(try self.freePool.newBuffer());
        }
    }

    fn checkBufferNodeNext(self: *Lines, line: *LineNode, buffer: *BufferNode) error{OutOfMemory}!void {
        if (buffer.next) |_| {} else {
            const newBuffer = try self.freePool.newBuffer();
            line.data.buffer.insertAfter(buffer, newBuffer);
        }
    }

    pub fn lineEnd(self: *Lines) void {
        defer self.change = true;

        var buffer: ?*BufferNode = self.currentBuffer;

        while (buffer) |b| {
            self.cursor.x += @intCast(b.data.len - self.cursor.offset);
            self.cursor.offset = 0;

            buffer = b.next;
        }

        self.currentBuffer = self.currentLine.data.buffer.last.?;
        self.cursor.offset = self.currentBuffer.data.len;
    }

    pub fn lineStart(self: *Lines) void {
        defer self.change = true;

        self.currentBuffer = self.currentLine.data.buffer.first.?;
        self.cursor.offset = 0;
        self.cursor.x = 0;
    }

    pub fn newLine(self: *Lines) error{OutOfMemory}!void {
        defer self.change = true;

        try self.checkBufferNodeNext(self.currentLine, self.currentBuffer);

        const next = self.currentBuffer.next.?;
        const line = try self.freePool.newLine();

        self.lines.insertAfter(self.currentLine, line);

        while (self.currentBuffer.next) |n| {
            self.currentLine.data.buffer.remove(n);
            line.data.buffer.append(n);
        }

        _ = try self.insertBufferNodeChars(line, next, 0, self.currentBuffer.data.handle[self.cursor.offset..self.currentBuffer.data.len]);
        self.currentBuffer.data.len = @intCast(self.cursor.offset);

        self.currentLine = line;
        self.currentBuffer = next;

        self.cursor.offset = 0;
        self.cursor.x = 0;
        self.cursor.y += 1;
    }

    pub fn toggleSelection(self: *Lines) void {
        defer self.change = true;
        if (self.selection) |_| {
            self.selection = null;
        } else {
            self.selection = self.cursor;
        }
    }

    fn checkCursor(self: *Lines, maxCols: u32, maxRows: u32) void {
        if (self.cursor.x >= maxCols + self.xOffset) {
            self.xOffset = self.cursor.x - maxCols + 1;
        } else if (self.cursor.x < self.xOffset) {
            self.xOffset = self.cursor.x;
        }

        if (self.cursor.y >= maxRows + self.yOffset) {
            self.yOffset = self.cursor.y - maxRows + 1;
        } else if (self.cursor.y < self.yOffset) {
            self.yOffset = self.cursor.y;
        }
    }

    pub fn clear(self: *Lines) void {
        defer self.change = true;

        self.cursor.x = 0;
        self.cursor.y = 0;
        self.cursor.offset = 0;

        var line = self.lines.last;

        while (line) |l| {
            line = l.prev;

            self.lines.remove(l);
            self.freePool.freeLine(l);
        }

        self.currentLine = self.freePool.newLine() catch unreachable;
        self.currentBuffer = self.freePool.newBuffer() catch unreachable;
        self.currentLine.data.buffer.append(self.currentBuffer);
        self.lines.append(self.currentLine);
    }

    pub fn rangeIter(self: *Lines, width: u32, height: u32, xOffset: i32, yOffset: i32, zOffset: i32, generator: *GlyphGenerator) ?RangeIter {
        return RangeIter.new(
            width,
            height,
            &self.xOffset,
            &self.yOffset,
            xOffset,
            yOffset,
            zOffset,
            self.cursor,
            self.currentLine,
            generator,
        );
    }

    fn print(self: *Lines) void {
        var line = self.lines.first;

        var count: u32 = 0;
        while (line) |l| {
            std.debug.print("{}:\n", .{count});
            l.data.print();

            line = l.next;
            count += 1;
        }
    }
};

pub const CharInfo = struct {
    transform: Matrix(4),
    char: u8,
    advance: u16,
    id: ?u32,
};

pub const GlyphGenerator = struct {
    font: FreeType,
    charIds: Map(u32, CharInfo),
    texture: Texture,
    count: u32,
    max: u32,
    size: u32,
    defaultTransform: Matrix(4),

    pub fn init(
        self: *GlyphGenerator,
        size: u32,
        maxGlyphs: u32,
        allocator: Allocator,
    ) error{ Init, OutOfMemory }!void {
        self.size = size + 2;
        self.texture = Texture.new(self.size, self.size, maxGlyphs, .r8, .red, .unsigned_byte, .@"2d_array", null);
        self.font = try FreeType.new("assets/font.ttf", size);
        self.charIds = Map(u32, CharInfo).init(allocator);
        self.defaultTransform = IDENTITY;

        try self.charIds.ensureTotalCapacity((maxGlyphs * 4) / 5);

        self.max = maxGlyphs;
        self.count = 0;

        _ = self.get(0) catch return error.Init;
    }

    pub fn get(self: *GlyphGenerator, code: u32) error{ Max, CharNotFound, OutOfMemory }!CharInfo {
        const set = try self.charIds.getOrPut(code);

        if (!set.found_existing) {
            if (self.count >= self.max) return error.Max;

            const char = self.font.findChar(code) catch return (self.charIds.getPtr(0) orelse return error.CharNotFound).*;
            const size: i32 = @intCast(self.size);
            var id: ?u32 = null;

            if (char.buffer) |b| {
                defer self.count += 1;

                id = @intCast(self.count);
                self.texture.pushData(char.width, char.height, self.count, .red, .unsigned_byte, b);
            }

            const xDelta = char.bearing[0];
            const yDelta = size - char.bearing[1];

            set.value_ptr.* = .{
                .char = @intCast(code),
                .advance = @intCast(char.advance),
                .id = id,
                .transform = self.defaultTransform.translate(.{@floatFromInt(xDelta), @floatFromInt(-yDelta), 0.0}),
            };
        }

        return set.value_ptr.*;
    }

    pub fn deinit(self: *const GlyphGenerator) void {
        self.texture.deinit();
    }
};

const Cursor = struct {
    x: u32,
    y: u32,
    offset: u32,

    fn order(first: Cursor, second: Cursor) [2]Cursor {
        var tuple: [2]Cursor = .{first, second};

        if (first.y > second.y) {
            tuple[0] = second;
            tuple[1] = first;
        } else if (first.y < second.y) {
            tuple[0] = first;
            tuple[1] = second;
        } else if (first.x > second.x) {
            tuple[1] = first;
            tuple[0] = second;
        } else if (first.x < second.x) {
            tuple[0] = first;
            tuple[1] = second;
        }

        return tuple;
    }
};

fn min(first: usize, second: usize) usize {
    return if (first < second) first else second;
}

fn max(first: usize, second: usize) usize {
    return if (first > second) first else second;
}

test "testing" {
    var fixedAllocator = FixedBufferAllocator.init(try std.testing.allocator.alloc(u8, 2 * 1024 * std.mem.page_size));
    defer std.testing.allocator.free(fixedAllocator.buffer);

    var freePool = FreePool.new(FixedBufferAllocator.init(try fixedAllocator.allocator().alloc(u8, 2 * 1024 * std.mem.page_size)));
    var lines: Lines = undefined;
    try lines.init(&freePool);

    const Behavior = enum {
        InsertString,
        NextLine,
        NewLine,
        PrevLine,
        CharBack,
        CharForward,
        DeleteChar,
    };

    try lines.insertString("#include <stdio.h>");
    try lines.newLine();
    try lines.newLine();
    try lines.insertString("int main() {");
    try lines.newLine();
    try lines.insertString("}");

    lines.moveLineUp(1);
    lines.lineEnd();

    try lines.newLine();
    try lines.insertString("    std.debug.print(\"Hello world\");");
    try lines.newLine();
    try lines.insertString("    return 0;");

    lines.moveLineUp(2);
    lines.lineEnd();

    try lines.newLine();
    try lines.newLine();
    lines.moveLineUp(10);

    try lines.deleteForward(1);

    var pcg = std.Random.Pcg.init(0);
    var random = pcg.random();
    const string = "Hello world";

    for (0..100000) |i| {
        const rand = random.enumValue(Behavior);
        std.debug.print("{} -> {}\n", .{i, rand});

        switch (rand) {
            .InsertString => try lines.insertString(string),
            .NextLine => lines.moveLineDown(1),
            .PrevLine => lines.moveLineUp(1),
            .CharBack => lines.moveBack(1),
            .CharForward => lines.moveFoward(1),
            .DeleteChar => try lines.deleteForward(1),
            .NewLine => try lines.newLine(),
        }
    }

    lines.print();
}
