const std = @import("std");
const val = @import("value.zig");

pub const OpCode = enum(u8) {
    OpConstant,
    OpReturn,
};

pub const Code = union(enum) {
    op_code: OpCode,
    index: u8,
};

pub const Chunk = struct {
    code: std.ArrayList(u8),
    constants: val.ValueArray,

    pub fn init(allocator: std.mem.Allocator) Chunk {
        return Chunk{
            .code = std.ArrayList(u8).init(allocator),
            .constants = val.ValueArray.init(allocator),
        };
    }

    pub fn write_code(self: *Chunk, byte: Code) !void {
        switch (byte) {
            .op_code => |code| try self.code.append(@intFromEnum(code)),
            .index => |code| try self.code.append(code),
        }
    }

    pub fn add_constant(self: *Chunk, value: val.Value) !usize {
        try self.constants.append(value);
        return self.constants.items.len - 1;
    }
};
