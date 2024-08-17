const std = @import("std");
const chk = @import("chunk.zig");
const dbg = @import("debug.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        const status = gpa.deinit();
        if (status == .leak) std.debug.print("Memory leak detected!\n", .{});
    }

    var chunk = chk.Chunk.init(allocator);
    try chunk.append(chk.OpCode.OpReturn);

    try dbg.disasemble_chunk(chunk, "test chunk");
}
