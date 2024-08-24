const std = @import("std");
const chk = @import("chunk.zig");
const dbg = @import("debug.zig");
const vm = @import("vm.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    var virtual_machine = vm.VirtualMachine.init(allocator);
    defer virtual_machine.deinit();

    var chunk = chk.Chunk.init(allocator);
    defer chunk.deinit();

    const index: usize = try chunk.add_constant(1.2);
    try chunk.write_code(@intFromEnum(chk.OpCode.OpConstant), 123);
    try chunk.write_code(@intCast(index), 123);
    try chunk.write_code(@intFromEnum(chk.OpCode.OpReturn), 123);

    try dbg.disasemble_chunk(chunk, "Test Chunk");
    try virtual_machine.interpret(chunk);
}

// Gather all tests
test {
    std.testing.refAllDecls(@This());
}
