const std = @import("std");
const expect = std.testing.expect;

const val = @import("value.zig");
const Value = @import("value.zig").Value;

pub const OpCode = enum(u8) {
    Constant,
    Nil,
    True,
    False,
    Pop,
    GetGlobal,
    DefineGlobal,
    Equal,
    Greater,
    Less,
    Add,
    Substract,
    Multiply,
    Divide,
    Not,
    Negate,
    Print,
    Return,
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

    pub fn deinit(self: Chunk) void {
        self.code.deinit();
        self.constants.deinit();
        self.lines.deinit();
    }

    pub fn write_code(self: *Chunk, byte: u8, line: usize) !void {
        try self.code.append(byte);
        try self.lines.append(line);
    }

    pub fn add_constant(self: *Chunk, value: val.Value) !usize {
        try self.constants.append(value);
        // Return the index of the added constant
        return self.constants.items.len - 1;
    }
};

test "chunk" {
    const allocator = std.testing.allocator;
    var chunk = Chunk.init(allocator);
    defer chunk.deinit();

    const index: usize = try chunk.add_constant(Value{ .Number = 1.2 });
    try chunk.write_code(@intFromEnum(OpCode.Constant), 123);
    try chunk.write_code(@intCast(index), 123);
    try chunk.write_code(@intFromEnum(OpCode.Return), 123);

    try expect(chunk.code.items.len == 3);
    try expect(std.mem.eql(u8, chunk.code.items, &([_]u8{ @intFromEnum(OpCode.Constant), 0, @intFromEnum(OpCode.Return) })));

    try expect(chunk.constants.items.len == 1);
    try expect(chunk.constants.items[0].Number == 1.2);

    try expect(chunk.lines.items.len == 3);
    try expect(std.mem.eql(usize, chunk.lines.items, &([_]usize{ 123, 123, 123 })));
}
