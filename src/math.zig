const std = @import("std");

pub const TO_DEGREE = 180.0 / std.math.pi;
pub const TO_RAD = std.math.pi / 180.0;

pub fn rad(degree: f32) f32 {
    return TO_RAD * degree;
}

pub const GroupType = enum(u8) {
    VecF32,
    MatrixF32,
};

pub fn Vec(comptime N: u32) type {
    return struct {
        data: [N]f32,

        const Self = @This();

        pub fn init(data: [N]f32) Self {
            return Self{
                .data = data,
            };
        }

        pub fn value(self: Self) [N]f32 {
            return self.data;
        }

        pub fn size() u32 {
            return N;
        }

        pub fn groupType() GroupType {
            return .VecF32;
        }

        pub fn inner() type {
            return f32;
        }

        pub fn sum(self: Self, other: Self) Self {
            var result: Self = undefined;

            for (0..N) |i| {
                result.data[i] = self.data[i] + other.data[i];
            }

            return result;
        }

        pub fn sub(self: Self, other: Self) Self {
            var result: Self = undefined;

            for (0..N) |i| {
                result.data[i] = self.data[i] - other.data[i];
            }

            return result;
        }

        pub fn dot(self: Self, other: Self) f32 {
            var result: f32 = 0;

            for (0..N) |i| {
                result += self.data[i] * other.data[i];
            }

            return result;
        }

        pub fn angle(self: Self, other: Self) f32 {
            const result: f32 = self.normalize().dot(other.normalize());

            return std.math.acos(result);
        }

        pub fn cross(self: Self, other: Self) Self {
            if (N != 3) @compileError("Cannot call cross product on non 3d vectors");

            return .{ .data = .{
                self.data[1] * other.data[2] - self.data[2] * other.data[1],
                self.data[2] * other.data[0] - self.data[0] * other.data[2],
                self.data[0] * other.data[1] - self.data[1] * other.data[0],
            } };
        }

        pub fn len(self: Self) f32 {
            var result: f32 = 0;

            for (0..N) |i| {
                result += self.data[i] * self.data[i];
            }

            return std.math.sqrt(result);
        }

        pub fn normalize(self: Self) Self {
            const length: f32 = self.len();

            var result: Self = undefined;

            for (0..N) |i| {
                result.data[i] = self.data[i] / length;
            }

            return result;
        }

        pub fn scale(self: Self, alpha: f32) Self {
            var result: Self = undefined;

            for (0..N) |i| {
                result.data[i] = self.data[i] * alpha;
            }

            return result;
        }

        pub fn mult(self: Self, matrix: [N][N]f32) Self {
            var result: Self = undefined;

            for (0..N) |i| {
                for (0..N) |j| {
                    result.data[i] = matrix[i][j] * self.dat[j];
                }
            }

            return result;
        }

        pub fn equal(self: Self, other: Self) bool {
            for (0..N) |i| {
                if (self.data[i] != other.data[i]) return false;
            }

            return true;
        }
    };
}

pub fn Matrix(comptime N: u32) type {
    if (N == 0 or N > 4) @compileError("Cannot create matrix matching this dimention");

    return struct {
        data: [N][N]f32,

        const Self = @This();

        pub fn value(self: Self) [N][N]f32 {
            return self.data;
        }

        pub fn size() u32 {
            return N;
        }

        pub fn groupType() GroupType {
            return .MatrixF32;
        }

        pub fn inner() type {
            return f32;
        }

        pub fn identity() Self {
            var result: Self = undefined;

            for (0..N) |i| {
                for (0..N) |j| {
                    result.data[i][j] = 0.0;
                }

                result.data[i][i] = 1.0;
            }

            return result;
        }

        pub fn scale(self: Self, data: [N]f32) Self {
            var result = self;

            for (0..N) |i| {
                result.data[i][i] = self.data[i][i] * data[i];
            }

            return result;
        }

        pub fn ortogonal(self: *Self, vec: Vec) Self {
            if (N != 4) @compileError("TODO: create that type of matrix for other dimention than 4");

            return self.mult(.{ .data = .{
                .{ vec.x * vec.x, vec.x * vec.y - vec.z, vec.x * vec.z + vec.y, 0.0 },
                .{ vec.y * vec.x + vec.z, vec.y * vec.y, vec.y * vec.z - vec.x, 0.0 },
                .{ vec.z * vec.x - vec.y, vec.z * vec.y + vec.x, vec.z * vec.z, 0.0 },
                .{ 0.0, 0.0, 0.0, 1.0 },
            } });
        }

        pub fn rotate(self: *Self, radians: f32, vec: Vec(3)) Self {
            if (N != 4) @compileError("TODO: create that type of matrix for other dimention than 4");

            const norm = vec.normalize().data;
            const cos = std.math.cos(radians);
            const sin = std.math.sin(radians);

            return self.mult(.{ .data = .{
                .{ norm[0] * norm[0] * (1 - cos) + cos, norm[1] * norm[0] * (1 - cos) - norm[2] * sin, norm[2] * norm[0] * (1 - cos) + norm[1] * sin, 0.0 },
                .{ norm[0] * norm[1] * (1 - cos) + norm[2] * sin, norm[1] * norm[1] * (1 - cos) + cos, norm[2] * norm[1] * (1 - cos) - norm[0] * sin, 0.0 },
                .{ norm[0] * norm[2] * (1 - cos) - norm[1] * sin, norm[1] * norm[2] * (1 - cos) + norm[0] * sin, norm[2] * norm[2] * (1 - cos) + cos, 0.0 },
                .{ 0.0, 0.0, 0.0, 1.0 },
            } });
        }

        pub fn translate(self: Self, data: [N - 1]f32) Self {
            var result = self;

            for (0..N - 1) |i| {
                result.data[i][N - 1] = self.data[i][N - 1] + data[i];
            }

            return result;
        }

        pub fn ortographic(self: Self, left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) Self {
            if (N != 4) @compileError("TODO: create that type of matrix for other dimention than 4");

            return self.mult(.{ .data = .{
                .{ 2.0 / (right - left), 0.0, 0.0, -(right + left) / (right - left) },
                .{ 0.0, 2.0 / (top - bottom), 0.0, (top + bottom) / (top - bottom) },
                .{ 0.0, 0.0, -2.0 / (far - near), (far + near) / (far - near) },
                .{ 0.0, 0.0, 0.0, 1.0 },
            } });
        }

        pub fn perspective(self: *Self, fovy: f32, aspect: f32, near: f32, far: f32) Self {
            if (N != 4) @compileError("TODO: create that type of matrix for other dimention than 4");

            const top = 1.0 / std.math.tan(fovy * 0.5);
            const r = far / (far - near);

            return self.mult(.{ .data = .{
                .{ top / aspect, 0.0, 0.0, 0.0 },
                .{ 0.0, top, 0.0, 0.0 },
                .{ 0.0, 0.0, r, 1.0 },
                .{ 0.0, 0.0, -r * near, 0.0 },
            } });
        }

        pub fn add(self: Self, other: Self) Self {
            var result = self;

            for (0..N) |i| {
                for (0..N) |j| {
                    result.data[i][j] = self.data[i][j] + other.data[i][j];
                }
            }

            return result;
        }

        pub fn mult(self: Self, other: Self) Self {
            if (N != 4) @compileError("TODO: create that type of matrix for other dimention than 4");

            return Self{ .data = .{
                .{ self.data[0][0] * other.data[0][0] + self.data[0][1] * other.data[1][0] + self.data[0][2] * other.data[2][0] + self.data[0][3] * other.data[3][0], self.data[0][0] * other.data[0][1] + self.data[0][1] * other.data[1][1] + self.data[0][2] * other.data[2][1] + self.data[0][3] * other.data[3][1], self.data[0][0] * other.data[0][2] + self.data[0][1] * other.data[1][2] + self.data[0][2] * other.data[2][2] + self.data[0][3] * other.data[3][2], self.data[0][0] * other.data[0][3] + self.data[0][1] * other.data[1][3] + self.data[0][2] * other.data[2][3] + self.data[0][3] * other.data[3][3] },
                .{ self.data[1][0] * other.data[0][0] + self.data[1][1] * other.data[1][0] + self.data[1][2] * other.data[2][0] + self.data[1][3] * other.data[3][0], self.data[1][0] * other.data[0][1] + self.data[1][1] * other.data[1][1] + self.data[1][2] * other.data[2][1] + self.data[1][3] * other.data[3][1], self.data[1][0] * other.data[0][2] + self.data[1][1] * other.data[1][2] + self.data[1][2] * other.data[2][2] + self.data[1][3] * other.data[3][2], self.data[1][0] * other.data[0][3] + self.data[1][1] * other.data[1][3] + self.data[1][2] * other.data[2][3] + self.data[1][3] * other.data[3][3] },
                .{ self.data[2][0] * other.data[0][0] + self.data[2][1] * other.data[1][0] + self.data[2][2] * other.data[2][0] + self.data[2][3] * other.data[3][0], self.data[2][0] * other.data[0][1] + self.data[2][1] * other.data[1][1] + self.data[2][2] * other.data[2][1] + self.data[2][3] * other.data[3][1], self.data[2][0] * other.data[0][2] + self.data[2][1] * other.data[1][2] + self.data[2][2] * other.data[2][2] + self.data[2][3] * other.data[3][2], self.data[2][0] * other.data[0][3] + self.data[2][1] * other.data[1][3] + self.data[2][2] * other.data[2][3] + self.data[2][3] * other.data[3][3] },
                .{ self.data[3][0] * other.data[0][0] + self.data[3][1] * other.data[1][0] + self.data[3][2] * other.data[2][0] + self.data[3][3] * other.data[3][0], self.data[3][0] * other.data[0][1] + self.data[3][1] * other.data[1][1] + self.data[3][2] * other.data[2][1] + self.data[3][3] * other.data[3][1], self.data[3][0] * other.data[0][2] + self.data[3][1] * other.data[1][2] + self.data[3][2] * other.data[2][2] + self.data[3][3] * other.data[3][2], self.data[3][0] * other.data[0][3] + self.data[3][1] * other.data[1][3] + self.data[3][2] * other.data[2][3] + self.data[3][3] * other.data[3][3] },
            } };
        }
    };
}
