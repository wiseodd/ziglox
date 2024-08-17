const std = @import("std");

pub const OpCode = enum {
    OpReturn,
};

pub const Chunk = std.ArrayList(OpCode);
