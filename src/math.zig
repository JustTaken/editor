const std = @import("std");

pub const TO_DEGREE = 180.0 / std.math.pi;
pub const TO_RAD = std.math.pi / 180.0;

pub fn rad(degree: f32) f32 {
    return TO_RAD * degree;
}

pub const GroupType = enum {
    VecF32,
    MatrixF32,
};

pub fn Vec(comptime N: u32) type {
    return struct {
        data: [N]f32,

        const Self = @This();

        pub fn init(data: [N]f32) Self {
            return Self {
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

            return .{
                .data = .{
                    self.data[1] * other.data[2] - self.data[2] * other.data[1],
                    self.data[2] * other.data[0] - self.data[0] * other.data[2],
                    self.data[0] * other.data[1] - self.data[1] * other.data[0],
                }
            };
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

        pub fn zero() Self {
            var result: Self = undefined;

            for (0..N) |i| {
                for (0..N) |j| {
                    result.data[i][j] = 0;
                }
            }

            return result;
        }

        pub fn scale(data: [N]f32) Self {
            var result = zero();

            for (0..N) |i| {
                result.data[i][i] = data[i];
            }

            return result;
        }

        pub fn xRotate(theta: f32) Self {
            if (N != 4) @compileError("TODO: create rotation matrix for dimension other than 4");

            var cos = std.math.cos(theta);
            var sin = std.math.sin(theta);

            if (cos * cos < 0.01) {
                cos = 0;
            }
            if (sin * sin < 0.01) {
                sin = 0;
            }

            return .{
                .data = .{
                    [N]f32 { 1.0, 0.0, 0.0, 0.0 },
                    [N]f32 { 0.0, cos, sin, 0.0 },
                    [N]f32 { 0.0, - sin, cos, 0.0 },
                    [N]f32 { 0.0, 0.0, 0.0, 1.0 },
                },
            };
        }

        pub fn yRotate(theta: f32) Self {
            if (N != 4) @compileError("TODO: create rotation matrix for dimension other than 4");

            var cos = std.math.cos(theta);
            var sin = std.math.sin(theta);

            if (cos * cos < 0.001) {
                cos = 0;
            }
            if (sin * sin < 0.001) {
                sin = 0;
            }

            return .{
                .data = .{
                    [N]f32 { cos, 0.0, - sin, 0.0 },
                    [N]f32 { 0.0, 1.0, 0.0, 0.0 },
                    [N]f32 { sin, 0.0, cos, 0.0 },
                    [N]f32 { 0.0, 0.0, 0.0, 1.0 },
                },
            };
        }

        pub fn ortogonal(vec: Vec) Self {
            if (N != 4) @compileError("TODO: create that type of matrix for other dimention than 4");

            return .{
                .data = .{
                    [N]f32 {vec.x * vec.x, vec.x * vec.y - vec.z, vec.x * vec.z + vec.y, 0.0},
                    [N]f32 {vec.y * vec.x + vec.z, vec.y * vec.y, vec.y * vec.z - vec.x, 0.0},
                    [N]f32 {vec.z * vec.x - vec.y, vec.z * vec.y + vec.x, vec.z * vec.z, 0.0},
                    [N]f32 {0.0, 0.0, 0.0, 1.0},
                }
            };
        }

        pub fn rotate(radians: f32, vec: Vec(3)) Self {
            if (N != 4) @compileError("TODO: create that type of matrix for other dimention than 4");

            const norm = vec.normalize().data;
            const cos = std.math.cos(radians);
            const sin = std.math.sin(radians);

            return .{
                .data = .{
                    [N]f32 {norm[0] * norm[0] * (1 - cos) + cos          , norm[1] * norm[0] * (1 - cos) - norm[2] * sin, norm[2] * norm[0] * (1 - cos) + norm[1] * sin, 0.0},
                    [N]f32 {norm[0] * norm[1] * (1 - cos) + norm[2] * sin, norm[1] * norm[1] * (1 - cos) + cos          , norm[2] * norm[1] * (1 - cos) - norm[0] * sin, 0.0},
                    [N]f32 {norm[0] * norm[2] * (1 - cos) - norm[1] * sin, norm[1] * norm[2] * (1 - cos) + norm[0] * sin, norm[2] * norm[2] * (1 - cos) + cos          , 0.0},
                    [N]f32 {0.0                                          , 0.0                                          , 0.0                                          , 1.0},
                }
            };
        }

        pub fn translate(data: [N - 1]f32) Self {
            var result = zero();

            for (0..N - 1) |i| {
                result.data[N - 1][i] = data[i];

                result.data[i][i] = 1.0;
            }

            result.data[N - 1][N - 1] = 1.0;

            return result;
        }

        pub fn perspective(fovy: f32, aspect: f32, near: f32, far: f32) Self {
            if (N != 4) @compileError("TODO: create that type of matrix for other dimention than 4");

            const top = 1.0 / std.math.tan(fovy * 0.5);
            const r = far / (far - near);

            return .{
                .data = .{
                    [N]f32 {top / aspect, 0.0, 0.0, 0.0},
                    [N]f32 { 0.0, top, 0.0, 0.0},
                    [N]f32 { 0.0, 0.0, r, 1.0},
                    [N]f32 { 0.0, 0.0, -r * near, 0.0},
                }
            };
        }

        pub fn mult(m1: Self, m2: Self) Self {
            if (N != 4) @compileError("TODO: create that type of matrix for other dimention than 4");

            return .{
                [N]f32 {m1[0][0] * m2[0][0] + m1[0][1] * m2[1][0] + m1[0][2] * m2[2][0] + m1[0][3] * m2[3][0], m1[0][0] * m2[0][1] + m1[0][1] * m2[1][1] + m1[0][2] * m2[2][1] + m1[0][3] * m2[3][1], m1[0][0] * m2[0][2] + m1[0][1] * m2[1][2] + m1[0][2] * m2[2][2] + m1[0][3] * m2[3][2], m1[0][0] * m2[0][3] + m1[0][1] * m2[1][3] + m1[0][2] * m2[2][3] + m1[0][3] * m2[3][3]},
                [N]f32 {m1[1][0] * m2[0][0] + m1[1][1] * m2[1][0] + m1[1][2] * m2[2][0] + m1[1][3] * m2[3][0], m1[1][0] * m2[0][1] + m1[1][1] * m2[1][1] + m1[1][2] * m2[2][1] + m1[1][3] * m2[3][1], m1[1][0] * m2[0][2] + m1[1][1] * m2[1][2] + m1[1][2] * m2[2][2] + m1[1][3] * m2[3][2], m1[1][0] * m2[0][3] + m1[1][1] * m2[1][3] + m1[1][2] * m2[2][3] + m1[1][3] * m2[3][3]},
                [N]f32 {m1[2][0] * m2[0][0] + m1[2][1] * m2[1][0] + m1[2][2] * m2[2][0] + m1[2][3] * m2[3][0], m1[2][0] * m2[0][1] + m1[2][1] * m2[1][1] + m1[2][2] * m2[2][1] + m1[2][3] * m2[3][1], m1[2][0] * m2[0][2] + m1[2][1] * m2[1][2] + m1[2][2] * m2[2][2] + m1[2][3] * m2[3][2], m1[2][0] * m2[0][3] + m1[2][1] * m2[1][3] + m1[2][2] * m2[2][3] + m1[2][3] * m2[3][3]},
                [N]f32 {m1[3][0] * m2[0][0] + m1[3][1] * m2[1][0] + m1[3][2] * m2[2][0] + m1[3][3] * m2[3][0], m1[3][0] * m2[0][1] + m1[3][1] * m2[1][1] + m1[3][2] * m2[2][1] + m1[3][3] * m2[3][1], m1[3][0] * m2[0][2] + m1[3][1] * m2[1][2] + m1[3][2] * m2[2][2] + m1[3][3] * m2[3][2], m1[3][0] * m2[0][3] + m1[3][1] * m2[1][3] + m1[3][2] * m2[2][3] + m1[3][3] * m2[3][3]},
            };
        }
    };
}

// pub const Matrix = struct {
//     handle: [4][4]f32,

//     pub fn scale(x: f32, y: f32, z: f32) [4][4]f32 {
//         return .{
//             [4]f32 { x, 0.0, 0.0, 0.0},
//             [4]f32 {0.0, y, 0.0, 0.0},
//             [4]f32 {0.0, 0.0, z, 0.0},
//             [4]f32 {0.0, 0.0, 0.0, 1.0}
//         };
//     }

//     pub fn x_rotate(theta: f32) [4][4]f32 {
//         var cos = std.math.cos(theta);
//         var sin = std.math.sin(theta);

//         if (cos * cos < 0.01) {
//             cos = 0;
//         }
//         if (sin * sin < 0.01) {
//             sin = 0;
//         }

//         return .{
//             [4]f32 { 1.0, 0.0, 0.0, 0.0 },
//             [4]f32 { 0.0, cos, sin, 0.0 },
//             [4]f32 { 0.0, - sin, cos, 0.0 },
//             [4]f32 { 0.0, 0.0, 0.0, 1.0 },
//         };
//     }

//     pub fn y_rotate(theta: f32) [4][4]f32 {
//         var cos = std.math.cos(theta);
//         var sin = std.math.sin(theta);

//         if (cos * cos < 0.001) {
//             cos = 0;
//         }
//         if (sin * sin < 0.001) {
//             sin = 0;
//         }

//         return .{
//             [4]f32 { cos, 0.0, - sin, 0.0 },
//             [4]f32 { 0.0, 1.0, 0.0, 0.0 },
//             [4]f32 { sin, 0.0, cos, 0.0 },
//             [4]f32 { 0.0, 0.0, 0.0, 1.0 },
//         };
//     }

//     pub fn ortogonal(vec: Vec) [4][4]f32 {
//         return .{
//             [4]f32 {vec.x * vec.x, vec.x * vec.y - vec.z, vec.x * vec.z + vec.y, 0.0},
//             [4]f32 {vec.y * vec.x + vec.z, vec.y * vec.y, vec.y * vec.z - vec.x, 0.0},
//             [4]f32 {vec.z * vec.x - vec.y, vec.z * vec.y + vec.x, vec.z * vec.z, 0.0},
//             [4]f32 {0.0, 0.0, 0.0, 1.0},
//         };
//     }

//     pub fn rotate(theta: f32, vec: Vec) [4][4]f32 {
//         const norm = vec.normalize();
//         const cos = std.math.cos(theta);
//         const sin = std.math.sin(theta);

//         return .{
//             [4]f32 {cos + norm.x * norm.x * (1 - cos), norm.y * norm.x * (1 - cos) + norm.z * sin, norm.z * norm.x * (1 - cos) + norm.y * sin, 0.0},
//             [4]f32 {norm.x * norm.y * (1 - cos) - norm.z * sin, cos + norm.y * norm.y * (1 - cos), norm.z * norm.y * (1 - cos) - norm.x * sin, 0.0},
//             [4]f32 {norm.x * norm.z * (1 - cos) + norm.y * sin, norm.y * norm.z * (1 - cos) + norm.x * sin, cos + norm.z * norm.z * (1 - cos), 0.0},
//             [4]f32 {0.0, 0.0, 0.0, 1.0},
//         };
//     }

//     pub fn translate(x: f32, y: f32, z: f32) [4][4]f32 {
//         return .{
//             [4]f32 {1.0, 0.0, 0.0, 0.0},
//             [4]f32 {0.0, 1.0, 0.0, 0.0},
//             [4]f32 {0.0, 0.0, 1.0, 0.0},
//             [4]f32 { x, y, z, 1.0},
//         };
//     }

//     pub fn perspective(fovy: f32, aspect: f32, near: f32, far: f32) [4][4]f32 {
//         const top = 1.0 / std.math.tan(fovy * 0.5);
//         const r = far / (far - near);

//         return [4][4]f32 {
//             [4]f32 {top / aspect, 0.0, 0.0, 0.0},
//             [4]f32 { 0.0, top, 0.0, 0.0},
//             [4]f32 { 0.0, 0.0, r, 1.0},
//             [4]f32 { 0.0, 0.0, -r * near, 0.0},
//         };
//     }

//     pub fn mult(m1: [4][4]f32, m2: [4][4]f32) [4][4]f32 {
//         return .{
//             [4]f32 {m1[0][0] * m2[0][0] + m1[0][1] * m2[1][0] + m1[0][2] * m2[2][0] + m1[0][3] * m2[3][0], m1[0][0] * m2[0][1] + m1[0][1] * m2[1][1] + m1[0][2] * m2[2][1] + m1[0][3] * m2[3][1], m1[0][0] * m2[0][2] + m1[0][1] * m2[1][2] + m1[0][2] * m2[2][2] + m1[0][3] * m2[3][2], m1[0][0] * m2[0][3] + m1[0][1] * m2[1][3] + m1[0][2] * m2[2][3] + m1[0][3] * m2[3][3]},
//             [4]f32 {m1[1][0] * m2[0][0] + m1[1][1] * m2[1][0] + m1[1][2] * m2[2][0] + m1[1][3] * m2[3][0], m1[1][0] * m2[0][1] + m1[1][1] * m2[1][1] + m1[1][2] * m2[2][1] + m1[1][3] * m2[3][1], m1[1][0] * m2[0][2] + m1[1][1] * m2[1][2] + m1[1][2] * m2[2][2] + m1[1][3] * m2[3][2], m1[1][0] * m2[0][3] + m1[1][1] * m2[1][3] + m1[1][2] * m2[2][3] + m1[1][3] * m2[3][3]},
//             [4]f32 {m1[2][0] * m2[0][0] + m1[2][1] * m2[1][0] + m1[2][2] * m2[2][0] + m1[2][3] * m2[3][0], m1[2][0] * m2[0][1] + m1[2][1] * m2[1][1] + m1[2][2] * m2[2][1] + m1[2][3] * m2[3][1], m1[2][0] * m2[0][2] + m1[2][1] * m2[1][2] + m1[2][2] * m2[2][2] + m1[2][3] * m2[3][2], m1[2][0] * m2[0][3] + m1[2][1] * m2[1][3] + m1[2][2] * m2[2][3] + m1[2][3] * m2[3][3]},
//             [4]f32 {m1[3][0] * m2[0][0] + m1[3][1] * m2[1][0] + m1[3][2] * m2[2][0] + m1[3][3] * m2[3][0], m1[3][0] * m2[0][1] + m1[3][1] * m2[1][1] + m1[3][2] * m2[2][1] + m1[3][3] * m2[3][1], m1[3][0] * m2[0][2] + m1[3][1] * m2[1][2] + m1[3][2] * m2[2][2] + m1[3][3] * m2[3][2], m1[3][0] * m2[0][3] + m1[3][1] * m2[1][3] + m1[3][2] * m2[2][3] + m1[3][3] * m2[3][3]},
//         };
//     }
// };

