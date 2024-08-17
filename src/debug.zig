const std = @import("std");
const expect = std.testing.expect;

const chk = @import("chunk.zig");
const val = @import("value.zig");

pub fn disasemble_chunk(chunk: chk.Chunk, name: []const u8) !void {
    std.debug.print("== {s} ==\n", .{name});

    var offset: usize = 0;
    while (offset < chunk.code.items.len) {
        offset = disassemble_instruction(chunk, offset);
    }
}

pub fn disassemble_instruction(chunk: chk.Chunk, offset: usize) usize {
    std.debug.print("{:0>4} ", .{offset});

    if (offset > 0 and chunk.lines.items[offset] == chunk.lines.items[offset - 1]) {
        std.debug.print("   | ", .{});
    } else {
        std.debug.print("{d:>4} ", .{chunk.lines.items[offset]});
    }

    const instruction: chk.OpCode = @enumFromInt(chunk.code.items[offset]);
    switch (instruction) {
        chk.OpCode.OpReturn => return simple_instruction("OP_RETURN", offset),
        chk.OpCode.OpConstant => return constant_instruction("OP_CONSTANT", chunk, offset),
    }
}

fn simple_instruction(name: []const u8, offset: usize) usize {
    std.debug.print("{s}\n", .{name});
    return offset + 1;
}

fn constant_instruction(name: []const u8, chunk: chk.Chunk, offset: usize) usize {
    const index: u8 = chunk.code.items[offset + 1];

    std.debug.print("{s:<16} {d:>4} '", .{ name, index });
    val.print_value(chunk.constants.items[index]);
    std.debug.print("'\n", .{});

    return offset + 2;
}
