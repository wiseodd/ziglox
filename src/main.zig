const std = @import("std");
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const debug = @import("debug.zig");
const VirtualMachine = @import("vm.zig").VirtualMachine;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();

    var vm = VirtualMachine.init(allocator);
    defer vm.deinit();

    // Command-line arguments
    const args = try std.process.argsAlloc(allocator);

    // Element 0 is always the program name
    if (args.len == 1) {
        try repl(allocator);
    } else if (args.len == 2) {
        try run_file(args[1]);
    } else {
        std.log.err("Usage: ziglox [path]\n", .{});
    }

    std.process.exit(0);
}

fn repl(allocator: std.mem.Allocator) !void {
    const MAX_LINE_SIZE = 1024;
    const stdin = std.io.getStdIn().reader();

    while (true) {
        std.debug.print("> ", .{});
        const maybe_input = try stdin.readUntilDelimiterOrEofAlloc(allocator, '\n', MAX_LINE_SIZE);

        // Akin to Rust's if-let
        if (maybe_input) |input| {
            defer allocator.free(input);
        } else {
            std.debug.print("\n", .{});
            break;
        }
    }
}

fn run_file(path: []u8) !void {
    std.debug.print("{s}", .{path});
}
