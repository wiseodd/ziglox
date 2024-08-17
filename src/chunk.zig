const std = @import("std");
const expect = std.testing.expect;

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
    lines: std.ArrayList(usize),

    pub fn init(allocator: std.mem.Allocator) Chunk {
        return Chunk{
            .code = std.ArrayList(u8).init(allocator),
            .constants = val.ValueArray.init(allocator),
            .lines = std.ArrayList(usize).init(allocator),
        };
    }

    pub fn write_code(self: *Chunk, byte: Code, line: usize) !void {
        switch (byte) {
            .op_code => |code| try self.code.append(@intFromEnum(code)),
            .index => |code| try self.code.append(code),
        }
        try self.lines.append(line);
    }

    pub fn add_constant(self: *Chunk, value: val.Value) !usize {
        try self.constants.append(value);
        return self.constants.items.len - 1;
    }
};

test "chunk" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    var chunk = Chunk.init(allocator);

    const index: usize = try chunk.add_constant(1.2);
    try chunk.write_code(Code{ .op_code = OpCode.OpConstant }, 123);
    try chunk.write_code(Code{ .index = @intCast(index) }, 123);
    try chunk.write_code(Code{ .op_code = OpCode.OpReturn }, 123);

    try expect(chunk.code.items.len == 3);
    try expect(std.mem.eql(u8, chunk.code.items, &([_]u8{ @intFromEnum(OpCode.OpConstant), 0, @intFromEnum(OpCode.OpReturn) })));

    try expect(chunk.constants.items.len == 1);
    try expect(chunk.constants.items[0] == 1.2);
}
