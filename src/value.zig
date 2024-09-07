const std = @import("std");
const testing = std.testing;

pub const ValueKind = enum {
    Bool,
    Number,
    Nil,
};

pub const Value = union(ValueKind) {
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

    pub fn equals(self: Value, other: Value) bool {
        const all_bools = self.is_boolean() and other.is_boolean();
        const all_nums = self.is_number() and other.is_number();
        const all_nils = self.is_nil() and other.is_nil();

        if (!all_bools and !all_nums and !all_nils) {
            return false;
        }

        return switch (self) {
            .Bool => self.Bool == other.Bool,
            .Nil => true,
            .Number => self.Number == other.Number,
        };
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

test "equals" {
    const cases = [_]struct { Value, Value, bool }{
        .{ Value.boolean(true), Value.boolean(true), true },
        .{ Value.boolean(true), Value.boolean(false), false },
        .{ Value.boolean(false), Value.boolean(true), false },
        .{ Value.boolean(true), Value.number(123), false },
        .{ Value.number(123), Value.boolean(false), false },
        .{ Value.number(222), Value.number(999), false },
        .{ Value.number(222.2), Value.number(222.2), true },
        .{ Value.number(222.2), Value.nil(), false },
        .{ Value.boolean(false), Value.nil(), false },
        .{ Value.nil(), Value.number(21.2), false },
        .{ Value.nil(), Value.boolean(true), false },
        .{ Value.nil(), Value.nil(), true },
    };

    for (cases) |case| {
        try testing.expectEqual(case[2], case[0].equals(case[1]));
    }
}

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
