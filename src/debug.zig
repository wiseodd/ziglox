const std = @import("std");
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const Value = @import("value.zig").Value;
const print_value = @import("value.zig").print_value;

pub fn disasemble_chunk(chunk: Chunk, name: []const u8) !void {
    std.debug.print("== {s} ==\n", .{name});

    var offset: usize = 0;
    while (offset < chunk.code.items.len) {
        // Offset is advanced when reading instruction
        offset = disassemble_instruction(chunk, offset);
    }
}

pub fn disassemble_instruction(chunk: Chunk, offset: usize) usize {
    // Right-aligned padding of zeros of length 4
    std.debug.print("{:0>4} ", .{offset});

    if (offset > 0 and chunk.lines.items[offset] == chunk.lines.items[offset - 1]) {
        std.debug.print("   | ", .{});
    } else {
        // Right-aligned padding of spaces of length 4
        std.debug.print("{d:>4} ", .{chunk.lines.items[offset]});
    }

    const instruction: OpCode = @enumFromInt(chunk.code.items[offset]);
    switch (instruction) {
        OpCode.OpConstant => return constant_instruction("OP_CONSTANT", chunk, offset),
        OpCode.OpAdd => return simple_instruction("OP_ADD", offset),
        OpCode.OpSubstract => return simple_instruction("OP_SUBTRACT", offset),
        OpCode.OpMultiply => return simple_instruction("OP_MULTIPLY", offset),
        OpCode.OpDivide => return simple_instruction("OP_DIVIDE", offset),
        OpCode.OpNegate => return simple_instruction("OP_NEGATE", offset),
        OpCode.OpReturn => return simple_instruction("OP_RETURN", offset),
    }
}

fn simple_instruction(name: []const u8, offset: usize) usize {
    std.debug.print("{s}\n", .{name});
    return offset + 1;
}

fn constant_instruction(name: []const u8, chunk: Chunk, offset: usize) usize {
    // Constants are stored in the bytecode chunk as 2 bytes:
    // The first byte is to specify that instruction "OP_CONSTANT".
    // The second one is to specify the index in chunk.constants where the constant
    // value is stored.
    const index: u8 = chunk.code.items[offset + 1];

    std.debug.print("{s:<16} {d:>4} '", .{ name, index });
    print_value(chunk.constants.items[index]);
    std.debug.print("'\n", .{});

    return offset + 2;
}
