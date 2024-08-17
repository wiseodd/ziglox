const std = @import("std");

pub const Value = f64;
pub const ValueArray = std.ArrayList(Value);

pub fn print_value(value: Value) void {
    std.debug.print("{d}", .{value});
}
