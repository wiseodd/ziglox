const std = @import("std");
const debug = @import("debug.zig");
const flags = @import("flags.zig");
const VirtualMachine = @import("vm.zig").VirtualMachine;
const InterpretError = @import("vm.zig").InterpretError;
const App = @import("yazap").App;
const Arg = @import("yazap").Arg;

pub fn main() !void {
    // Initialize memory allocator
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var vm = VirtualMachine.init(allocator);
    defer vm.deinit();

    // Command-line arguments
    var app = App.init(allocator, "ziglox", "Lox bytecode compiler in Zig.");
    defer app.deinit();

    var myapp = app.rootCommand();
    try myapp.addArg(Arg.positional("FILE", null, null));
    try myapp.addArg(Arg.booleanOption("debug", 'd', null));
    const args = try app.parseProcess();

    if (args.containsArg("debug")) {
        flags.DEBUG_PRINT_CODE = true;
        flags.DEBUG_TRACE_EXECUTION = true;
    }

    if (args.getSingleValue("FILE")) |f| {
        try run_file(f, vm, allocator);
    } else {
        try repl(vm, allocator);
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
            _ = vm.interpret(input) catch {};
        } else {
            std.debug.print("\n", .{});
            break;
        }
    }
}

fn run_file(path: []const u8, vm: *VirtualMachine, allocator: std.mem.Allocator) !void {
    const source: []u8 = read_file(path, allocator);
    defer allocator.free(source);

    _ = vm.interpret(source) catch |err| switch (err) {
        InterpretError.CompileError => std.process.exit(65),
        InterpretError.RuntimeError => std.process.exit(70),
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
        std.log.err("Failed to get metadata of \"{s}\".\n", .{path});
        std.process.exit(74);
    };
    const buffer: []u8 = file.readToEndAlloc(allocator, stat.size) catch {
        std.log.err("Not enough memory to read \"{s}\".\n", .{path});
        std.process.exit(74);
    };

    return buffer;
}
