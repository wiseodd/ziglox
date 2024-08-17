const std = @import("std");
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;

pub fn disasemble_chunk(chunk: Chunk, name: []const u8) !void {
    std.debug.print("== {s} ==\n", .{name});

    var offset: usize = 0;
    while (offset < chunk.items.len) {
        offset = disassemble_instruction(chunk, offset);
    }
}

pub fn disassemble_instruction(chunk: Chunk, offset: usize) usize {
    std.debug.print("{:0>4} ", .{offset});

    const instruction: OpCode = chunk.items[offset];
    switch (instruction) {
        OpCode.OpReturn => return simple_instruction("OP_RETURN", offset),
    }
}

fn simple_instruction(name: []const u8, offset: usize) usize {
    std.debug.print("{s}\n", .{name});
    return offset + 1;
}
