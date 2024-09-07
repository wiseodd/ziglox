const std = @import("std");
const testing = std.testing;

pub const Value = union(enum) {
    Bool: bool,
    Number: f64,
    Nil: void,

    pub fn print(self: Value) void {
        switch (self) {
            .Bool => |val| std.debug.print("{}", .{val}),
            .Number => |val| std.debug.print("{d}", .{val}),
            .Nil => std.debug.print("nil", .{}),
        }
    }

    pub inline fn is_falsey(self: Value) bool {
        if (self.is_nil()) return true;

        return switch (self) {
            .Bool => |val| !val,
            else => false,
        };
    }

    pub inline fn boolean(value: bool) Value {
        return Value{ .Bool = value };
    }

    pub inline fn number(value: f64) Value {
        return Value{ .Number = value };
    }

    pub inline fn nil() Value {
        return Value{ .Nil = {} };
    }

    pub inline fn is_boolean(self: Value) bool {
        return switch (self) {
            .Bool => true,
            else => false,
        };
    }

    pub inline fn is_number(self: Value) bool {
        return switch (self) {
            .Number => true,
            else => false,
        };
    }

    pub inline fn is_nil(self: Value) bool {
        return switch (self) {
            .Nil => true,
            else => false,
        };
    }
};

pub const ValueArray = std.ArrayList(Value);

test "is_falsey" {
    try testing.expectEqual(false, (Value{ .Bool = true }).is_falsey());
    try testing.expectEqual(true, (Value{ .Bool = false }).is_falsey());
    try testing.expectEqual(false, (Value{ .Number = 123.322 }).is_falsey());
    try testing.expectEqual(true, (Value{ .Nil = {} }).is_falsey());
}

test "is_boolean" {
    try testing.expectEqual(true, (Value{ .Bool = true }).is_boolean());
    try testing.expectEqual(false, (Value{ .Number = 123.322 }).is_boolean());
    try testing.expectEqual(false, (Value{ .Nil = {} }).is_boolean());
}

test "is_number" {
    try testing.expectEqual(false, (Value{ .Bool = true }).is_number());
    try testing.expectEqual(true, (Value{ .Number = 123.322 }).is_number());
    try testing.expectEqual(false, (Value{ .Nil = {} }).is_number());
}

test "is_nil" {
    try testing.expectEqual(false, (Value{ .Bool = true }).is_nil());
    try testing.expectEqual(false, (Value{ .Number = 123.322 }).is_nil());
    try testing.expectEqual(true, (Value{ .Nil = {} }).is_nil());
}
