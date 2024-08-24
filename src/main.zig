const std = @import("std");
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const debug = @import("debug.zig");
const VirtualMachine = @import("vm.zig").VirtualMachine;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    var virtual_machine = VirtualMachine.init(allocator);
    defer virtual_machine.deinit();

    var chunk = Chunk.init(allocator);
    defer chunk.deinit();

    var index: usize = try chunk.add_constant(1.2);
    try chunk.write_code(@intFromEnum(OpCode.OpConstant), 123);
    try chunk.write_code(@intCast(index), 123);

    index = try chunk.add_constant(3.4);
    try chunk.write_code(@intFromEnum(OpCode.OpConstant), 123);
    try chunk.write_code(@intCast(index), 123);

    try chunk.write_code(@intFromEnum(OpCode.OpAdd), 123);

    index = try chunk.add_constant(5.6);
    try chunk.write_code(@intFromEnum(OpCode.OpConstant), 123);
    try chunk.write_code(@intCast(index), 123);

    try chunk.write_code(@intFromEnum(OpCode.OpDivide), 123);
    try chunk.write_code(@intFromEnum(OpCode.OpNegate), 123);

    try chunk.write_code(@intFromEnum(OpCode.OpReturn), 123);

    // try debug.disasemble_chunk(chunk, "Test Chunk");
    try virtual_machine.interpret(chunk);
}

// Gather all tests
test {
    std.testing.refAllDecls(@This());
}
