const std = @import("std");
const chk = @import("chunk.zig");
const dbg = @import("debug.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    var chunk = chk.Chunk.init(allocator);

    const index: usize = try chunk.add_constant(1.2);
    try chunk.write_code(chk.Code{ .op_code = chk.OpCode.OpConstant }, 123);
    try chunk.write_code(chk.Code{ .index = @intCast(index) }, 123);
    try chunk.write_code(chk.Code{ .op_code = chk.OpCode.OpReturn }, 123);

    try dbg.disasemble_chunk(chunk, "Test Chunk");
}

// Gather all tests
test {
    std.testing.refAllDecls(@This());
}
