const std = @import("std");
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const Value = @import("value.zig").Value;
const print_value = @import("value.zig").print_value;
const debug = @import("debug.zig");
const flags = @import("flags.zig");
const Parser = @import("compiler.zig").Parser;

pub const InterpretError = error{
    CompileError,
    RuntimeError,
};

pub const VirtualMachine = struct {
    chunk: Chunk,
    ip: [*]u8,
    stack: std.ArrayList(Value),

    pub fn init(allocator: std.mem.Allocator) VirtualMachine {
        return VirtualMachine{
            .chunk = Chunk.init(allocator),
            .ip = undefined,
            .stack = std.ArrayList(Value).init(allocator),
        };
    }

    pub fn deinit(self: *VirtualMachine) void {
        self.chunk.deinit();
        self.stack.deinit();
    }

    pub fn interpret(self: *VirtualMachine, source: []const u8) InterpretError!void {
        var parser = Parser.init(source, &self.chunk);
        try parser.compile();

        // Initialize the instruction pointer to the start of the chunk's bytecode
        self.ip = self.chunk.code.items.ptr;

        try self.run();
    }

    fn run(self: *VirtualMachine) InterpretError!void {
        if (self.chunk.code.items.len == 0) return;

        // Note that self.read_byte() advances the pointer
        while (true) {
            if (flags.DEBUG_TRACE_EXECUTION) {
                std.debug.print("          ", .{});
                for (self.stack.items) |slot| {
                    std.debug.print("[ ", .{});
                    print_value(slot);
                    std.debug.print(" ]", .{});
                }
                std.debug.print("\n", .{});

                // @intFromPtr converts a pointer to its usize address.
                // Since arrays are contiguous, we can compute the distance from the
                // first element.
                const offset: usize = @intFromPtr(self.ip) - @intFromPtr(self.chunk.code.items.ptr);
                _ = debug.disassemble_instruction(self.chunk, offset);
            }

            const instruction: OpCode = @enumFromInt(self.read_byte());

            switch (instruction) {
                OpCode.Constant => {
                    const constant: Value = self.read_constant();
                    self.stack.append(constant) catch {
                        return InterpretError.RuntimeError;
                    };
                },
                OpCode.Add => try self.binary_op(OpCode.Add),
                OpCode.Substract => try self.binary_op(OpCode.Substract),
                OpCode.Multiply => try self.binary_op(OpCode.Multiply),
                OpCode.Divide => try self.binary_op(OpCode.Divide),
                OpCode.Negate => {
                    self.stack.append(-self.stack.pop()) catch {
                        return InterpretError.RuntimeError;
                    };
                },
                OpCode.Return => {
                    const retval: Value = self.stack.pop();

                    if (flags.DEBUG_TRACE_EXECUTION) {
                        print_value(retval);
                        std.debug.print("\n", .{});
                    }

                    return;
                },
            }
        }
    }

    // Inline function to emulate C macro
    inline fn read_byte(self: *VirtualMachine) u8 {
        // self.ip is a many-item pointer.
        // The first element points to start of the slice.
        const value: u8 = self.ip[0];
        // Pointer arithmetic below. We advance self.ip to the pointer of the next
        // element in the slice.
        self.ip += 1;
        return value;
    }

    inline fn read_constant(self: *VirtualMachine) Value {
        return self.chunk.constants.items[self.read_byte()];
    }

    inline fn binary_op(self: *VirtualMachine, op: OpCode) InterpretError!void {
        // The first-popped value is val2 since it's a stack (LIFO)
        const val2: Value = self.stack.pop();
        const val1: Value = self.stack.pop();
        const res: Value = switch (op) {
            OpCode.Add => val1 + val2,
            OpCode.Substract => val1 - val2,
            OpCode.Multiply => val1 * val2,
            OpCode.Divide => val1 / val2,
            else => return InterpretError.RuntimeError,
        };
        self.stack.append(res) catch {
            return InterpretError.RuntimeError;
        };
    }
};

fn test_init_chunk(chunk: *Chunk) !void {
    var index: usize = try chunk.add_constant(1.2);
    try chunk.write_code(@intFromEnum(OpCode.Constant), 123);
    try chunk.write_code(@intCast(index), 123);

    index = try chunk.add_constant(3.4);
    try chunk.write_code(@intFromEnum(OpCode.Constant), 123);
    try chunk.write_code(@intCast(index), 123);

    try chunk.write_code(@intFromEnum(OpCode.Add), 123);

    index = try chunk.add_constant(5.6);
    try chunk.write_code(@intFromEnum(OpCode.Constant), 123);
    try chunk.write_code(@intCast(index), 123);

    try chunk.write_code(@intFromEnum(OpCode.Divide), 123);
    try chunk.write_code(@intFromEnum(OpCode.Negate), 123);

    try chunk.write_code(@intFromEnum(OpCode.Return), 123);
}

test "vm_init" {
    const allocator = std.testing.allocator;
    var vm = VirtualMachine.init(allocator);
    defer vm.deinit();

    try std.testing.expect(vm.stack.items.len == 0);
}

test "vm_run_empty_chunk" {
    const allocator = std.testing.allocator;
    var vm = VirtualMachine.init(allocator);
    var chunk = Chunk.init(allocator);
    defer vm.deinit();
    defer chunk.deinit();

    vm.chunk = chunk;
    vm.ip = chunk.code.items.ptr;

    try vm.run();
}

test "vm_run" {
    const allocator = std.testing.allocator;
    var vm = VirtualMachine.init(allocator);
    var chunk = Chunk.init(allocator);
    defer vm.deinit();
    defer chunk.deinit();

    try test_init_chunk(&chunk);

    vm.chunk = chunk;
    vm.ip = chunk.code.items.ptr;

    try vm.run();

    try std.testing.expectEqual(
        vm.chunk.code.items.len,
        @intFromPtr(vm.ip) - @intFromPtr(vm.chunk.code.items.ptr),
    );

    try std.testing.expectEqual(0, vm.stack.items.len);
}

test "vm_read_byte" {
    const allocator = std.testing.allocator;
    var vm = VirtualMachine.init(allocator);
    var chunk = Chunk.init(allocator);
    defer vm.deinit();
    defer chunk.deinit();

    try test_init_chunk(&chunk);

    vm.chunk = chunk;
    vm.ip = chunk.code.items.ptr;

    const expectations = [_]OpCode{ OpCode.Constant, OpCode.Constant, OpCode.Add };

    for (expectations) |exp| {
        const instruction: OpCode = @enumFromInt(vm.read_byte());
        try std.testing.expect(instruction == exp);
        _ = vm.read_byte();
    }
}

test "vm_read_const" {
    const allocator = std.testing.allocator;
    var vm = VirtualMachine.init(allocator);
    var chunk = Chunk.init(allocator);
    defer vm.deinit();
    defer chunk.deinit();

    try test_init_chunk(&chunk);

    vm.chunk = chunk;
    vm.ip = chunk.code.items.ptr;

    const expectations = [_]Value{ 1.2, 3.4 };

    for (expectations) |exp| {
        _ = vm.read_byte();
        const constant: Value = vm.read_constant();
        try std.testing.expect(constant == exp);
    }
}

test "vm_binary_op" {
    const allocator = std.testing.allocator;
    var vm = VirtualMachine.init(allocator);
    defer vm.deinit();

    try vm.stack.append(6);
    try vm.stack.append(3);
    try std.testing.expect(std.mem.eql(Value, vm.stack.items, &[2]Value{ 6, 3 }));

    try vm.binary_op(OpCode.Add);
    try std.testing.expect(std.mem.eql(Value, vm.stack.items, &[1]Value{9}));

    try vm.stack.append(4);
    try std.testing.expect(std.mem.eql(Value, vm.stack.items, &[2]Value{ 9, 4 }));
    try vm.binary_op(OpCode.Substract);
    try std.testing.expect(std.mem.eql(Value, vm.stack.items, &[1]Value{5}));

    try vm.stack.append(3.2);
    try std.testing.expect(std.mem.eql(Value, vm.stack.items, &[2]Value{ 5, 3.2 }));
    try vm.binary_op(OpCode.Multiply);
    try std.testing.expect(std.mem.eql(Value, vm.stack.items, &[1]Value{16}));

    try vm.stack.append(8.0);
    try std.testing.expect(std.mem.eql(Value, vm.stack.items, &[2]Value{ 16, 8 }));
    try vm.binary_op(OpCode.Divide);
    try std.testing.expect(std.mem.eql(Value, vm.stack.items, &[1]Value{2}));
}
