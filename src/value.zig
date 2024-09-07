const std = @import("std");

pub const Value = union(enum) {
    Bool: bool,
    Number: f64,
    Nil: void,
};

pub const ValueArray = std.ArrayList(Value);

pub fn print_value(value: Value) void {
    switch (value) {
        .Bool => |val| std.debug.print("{}", .{val}),
        .Number => |val| std.debug.print("{d}", .{val}),
        .Nil => std.debug.print("nil", .{}),
    }
}
