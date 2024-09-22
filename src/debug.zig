const std = @import("std");
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const Value = @import("value.zig").Value;

pub fn disasemble_chunk(chunk: *Chunk, name: []const u8) void {
    std.debug.print("== {s} ==\n", .{name});

    var offset: usize = 0;
    while (offset < chunk.code.items.len) {
        // Offset is advanced when reading instruction
        offset = disassemble_instruction(chunk, offset);
    }
}

pub fn disassemble_instruction(chunk: *Chunk, offset: usize) usize {
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
        OpCode.Constant => return constant_instruction("OP_CONSTANT", chunk, offset),
        OpCode.Nil => return simple_instruction("OP_NIL", offset),
        OpCode.True => return simple_instruction("OP_TRUE", offset),
        OpCode.False => return simple_instruction("OP_FALSE", offset),
        OpCode.GetLocal => return byte_instruction("OP_GET_LOCAL", chunk, offset),
        OpCode.SetLocal => return byte_instruction("OP_SET_LOCAL", chunk, offset),
        OpCode.GetGlobal => return constant_instruction("OP_GET_GLOBAL", chunk, offset),
        OpCode.DefineGlobal => return constant_instruction("OP_DEFINE_GLOBAL", chunk, offset),
        OpCode.SetGlobal => return constant_instruction("OP_SET_GLOBAL", chunk, offset),
        OpCode.Equal => return simple_instruction("OP_EQUAL", offset),
        OpCode.Pop => return simple_instruction("OP_POP", offset),
        OpCode.Greater => return simple_instruction("OP_GREATER", offset),
        OpCode.Less => return simple_instruction("OP_LESS", offset),
        OpCode.Add => return simple_instruction("OP_ADD", offset),
        OpCode.Substract => return simple_instruction("OP_SUBTRACT", offset),
        OpCode.Multiply => return simple_instruction("OP_MULTIPLY", offset),
        OpCode.Divide => return simple_instruction("OP_DIVIDE", offset),
        OpCode.Not => return simple_instruction("OP_NOT", offset),
        OpCode.Negate => return simple_instruction("OP_NEGATE", offset),
        OpCode.Print => return simple_instruction("OP_PRINT", offset),
        OpCode.Jump => return jump_instruction("OP_JUMP", 1, chunk, offset),
        OpCode.JumpIfFalse => return jump_instruction("OP_JUMP_IF_FALSE", 1, chunk, offset),
        OpCode.Loop => return jump_instruction("OP_LOOP", -1, chunk, offset),
        OpCode.Return => return simple_instruction("OP_RETURN", offset),
    }
}

fn simple_instruction(name: []const u8, offset: usize) usize {
    std.debug.print("{s}\n", .{name});
    return offset + 1;
}

fn constant_instruction(name: []const u8, chunk: *Chunk, offset: usize) usize {
    // Constants are stored in the bytecode chunk as 2 bytes:
    // The first byte is to specify that instruction "OP_CONSTANT".
    // The second one is to specify the index in chunk.constants where the constant
    // value is stored.
    const index: u8 = chunk.code.items[offset + 1];

    std.debug.print("{s:<16} {d:>4} '", .{ name, index });
    chunk.constants.items[index].print();
    std.debug.print("'\n", .{});

    return offset + 2;
}

fn byte_instruction(name: []const u8, chunk: *Chunk, offset: usize) usize {
    const slot = chunk.code.items[offset + 1];
    std.debug.print("{s:<16} {d:>4}\n", .{ name, slot });

    return offset + 2;
}

fn jump_instruction(name: []const u8, sign: i8, chunk: *Chunk, offset: usize) usize {
    var jump: i32 = @intCast(chunk.code.items[offset + 1]);
    jump <<= @intCast(8);
    jump |= @intCast(chunk.code.items[offset + 2]);

    // `offset + 3` is the next instruction, skipping over the 2-byte jump operand.
    const offset_signed: i32 = @intCast(offset);
    std.debug.print("{s:<16} {d:>4} -> {d}\n", .{ name, offset, offset_signed + 3 + sign * jump });

    return offset + 3;
}
