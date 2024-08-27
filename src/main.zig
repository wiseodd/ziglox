const std = @import("std");
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const debug = @import("debug.zig");
const VirtualMachine = @import("vm.zig").VirtualMachine;
const InterpretError = @import("vm.zig").InterpretError;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();

    var vm = VirtualMachine.init(allocator);
    defer vm.deinit();

    // Command-line arguments
    const args = try std.process.argsAlloc(allocator);

    // Element 0 is always the program name
    if (args.len == 1) {
        try repl(&vm, allocator);
    } else if (args.len == 2) {
        try run_file(args[1], &vm, allocator);
    } else {
        std.log.err("Usage: ziglox [path]\n", .{});
    }

    std.process.exit(0);
}

fn repl(vm: *VirtualMachine, allocator: std.mem.Allocator) !void {
    const MAX_LINE_SIZE = 1024;
    const stdin = std.io.getStdIn().reader();

    while (true) {
        std.debug.print("\n> ", .{});
        const maybe_input = try stdin.readUntilDelimiterOrEofAlloc(allocator, '\n', MAX_LINE_SIZE);

        // Akin to Rust's if-let
        if (maybe_input) |input| {
            defer allocator.free(input);
            const chunk = Chunk.init(allocator);
            defer chunk.deinit();
            _ = vm.interpret(chunk) catch {
                std.debug.print("Not implemented yet!\n", .{});
            };
        } else {
            std.debug.print("\n", .{});
            break;
        }
    }
}

fn run_file(path: []const u8, vm: *VirtualMachine, allocator: std.mem.Allocator) !void {
    const source: []u8 = read_file(path, allocator);
    std.debug.print("{s}", .{source});

    const chunk = Chunk.init(allocator);
    defer chunk.deinit();
    _ = vm.interpret(chunk) catch |err| switch (err) {
        InterpretError.CompileError => {
            std.debug.print("Not implemented yet!\n", .{});
            std.process.exit(65);
        },
        InterpretError.RuntimeError => {
            std.debug.print("Not implemented yet!\n", .{});
            std.process.exit(70);
        },
    };

    return;
}

fn read_file(path: []const u8, allocator: std.mem.Allocator) []u8 {
    const file: std.fs.File = std.fs.cwd().openFile(path, .{ .mode = .read_only }) catch {
        std.log.err("Could not open file \"{s}\".\n", .{path});
        return std.process.exit(74);
    };
    defer file.close();

    const stat: std.fs.File.Stat = file.stat() catch {
        std.log.err("Failed to metadata of \"{s}\".\n", .{path});
        std.process.exit(74);
    };
    const buffer: []u8 = file.readToEndAlloc(allocator, stat.size) catch {
        std.log.err("Not enough memory to read \"{s}\".\n", .{path});
        std.process.exit(74);
    };

    return buffer;
}
