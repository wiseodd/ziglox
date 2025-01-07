const std = @import("std");
const Value = @import("value.zig").Value;

pub fn clock_native(arg_count: usize, args: [*]Value) Value {
    _ = arg_count;
    _ = args;

    const micro: f64 = @floatFromInt(std.time.microTimestamp());
    const cast: f64 = 1e6;

    return Value.number(micro / cast);
}
