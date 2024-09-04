const std = @import("std");
const testing = std.testing;
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
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) VirtualMachine {
        return VirtualMachine{
            .chunk = Chunk.init(allocator),
            .ip = undefined,
            .stack = std.ArrayList(Value).init(allocator),
            .allocator = allocator,
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
                _ = debug.disassemble_instruction(&self.chunk, offset);
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
                    switch (self.peek(0)) {
                        .Number => {
                            const negated = Value{ .Number = -self.stack.pop().Number };
                            self.stack.append(negated) catch {
                                return InterpretError.RuntimeError;
                            };
                        },
                        else => {
                            self.runtime_error("Operand must be a number.", .{});
                            return InterpretError.RuntimeError;
                        },
                    }
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

    fn peek(self: *VirtualMachine, distance: usize) Value {
        return self.stack.items[self.stack.items.len - 1 - distance];
    }

    fn runtime_error(self: *VirtualMachine, comptime format: []const u8, args: anytype) void {
        std.debug.print(format, args);
        std.debug.print("\n", .{});

        // Distance between the current ponter to the beginning.
        // Note that there's `- 1` there because `self.ip` has been advanced by one
        // when an instruction is read via `self.read_byte()`.
        const instruction: usize = @intFromPtr(self.ip) - @intFromPtr(self.chunk.code.items.ptr) - 1;
        const line: usize = self.chunk.lines.items[instruction];
        std.debug.print("[Line {}] in script\n", .{line});

        self.reset_stack();
    }

    pub fn reset_stack(self: *VirtualMachine) void {
        self.stack.deinit();
        self.stack = std.ArrayList(Value).init(self.allocator);
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
        const val2 = self.stack.pop().Number;
        const val1 = self.stack.pop().Number;
        const res = switch (op) {
            OpCode.Add => val1 + val2,
            OpCode.Substract => val1 - val2,
            OpCode.Multiply => val1 * val2,
            OpCode.Divide => val1 / val2,
            else => return InterpretError.RuntimeError,
        };
        self.stack.append(Value{ .Number = res }) catch {
            return InterpretError.RuntimeError;
        };
    }
};

fn test_init_chunk(chunk: *Chunk) !void {
    var index: usize = try chunk.add_constant(Value{ .Number = 1.2 });
    try chunk.write_code(@intFromEnum(OpCode.Constant), 123);
    try chunk.write_code(@intCast(index), 123);

    index = try chunk.add_constant(Value{ .Number = 3.4 });
    try chunk.write_code(@intFromEnum(OpCode.Constant), 123);
    try chunk.write_code(@intCast(index), 123);

    try chunk.write_code(@intFromEnum(OpCode.Add), 123);

    index = try chunk.add_constant(Value{ .Number = 5.6 });
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

    try testing.expect(vm.stack.items.len == 0);
}

test "vm_run_empty_chunk" {
    const allocator = std.testing.allocator;
    var vm = VirtualMachine.init(allocator);
    defer vm.deinit();

    vm.ip = vm.chunk.code.items.ptr;

    try vm.run();
}

test "vm_run" {
    const allocator = std.testing.allocator;
    var vm = VirtualMachine.init(allocator);
    defer vm.deinit();

    try test_init_chunk(&vm.chunk);

    vm.ip = vm.chunk.code.items.ptr;

    try vm.run();

    try testing.expectEqual(
        vm.chunk.code.items.len,
        @intFromPtr(vm.ip) - @intFromPtr(vm.chunk.code.items.ptr),
    );

    try testing.expectEqual(0, vm.stack.items.len);
}

test "vm_read_byte" {
    const allocator = std.testing.allocator;
    var vm = VirtualMachine.init(allocator);
    defer vm.deinit();

    try test_init_chunk(&vm.chunk);

    vm.ip = vm.chunk.code.items.ptr;

    const expectations = [_]OpCode{ OpCode.Constant, OpCode.Constant, OpCode.Add };

    for (expectations) |exp| {
        const instruction: OpCode = @enumFromInt(vm.read_byte());
        try testing.expect(instruction == exp);
        _ = vm.read_byte();
    }
}

test "vm_read_const" {
    const allocator = std.testing.allocator;
    var vm = VirtualMachine.init(allocator);
    defer vm.deinit();

    try test_init_chunk(&vm.chunk);

    vm.ip = vm.chunk.code.items.ptr;

    const expectations = [_]Value{ Value{ .Number = 1.2 }, Value{ .Number = 3.4 } };

    for (expectations) |exp| {
        _ = vm.read_byte();
        const constant: Value = vm.read_constant();
        try testing.expect(constant.Number == exp.Number);
    }
}

test "vm_binary_op" {
    const allocator = std.testing.allocator;
    var vm = VirtualMachine.init(allocator);
    defer vm.deinit();

    try vm.stack.append(Value{ .Number = 6 });
    try vm.stack.append(Value{ .Number = 3 });

    try testing.expectEqual(2, vm.stack.items.len);
    try testing.expect(std.meta.eql(vm.stack.items[0], Value{ .Number = 6 }));
    try testing.expect(std.meta.eql(vm.stack.items[1], Value{ .Number = 3 }));

    try vm.binary_op(OpCode.Add);

    try testing.expectEqual(1, vm.stack.items.len);
    try testing.expect(std.meta.eql(vm.stack.items[0], Value{ .Number = 9 }));

    try vm.stack.append(Value{ .Number = 4 });

    try testing.expectEqual(2, vm.stack.items.len);
    try testing.expect(std.meta.eql(vm.stack.items[0], Value{ .Number = 9 }));
    try testing.expect(std.meta.eql(vm.stack.items[1], Value{ .Number = 4 }));

    try vm.binary_op(OpCode.Substract);
    // try testing.expect(std.mem.eql(Value, vm.stack.items, &[1]Value{Value{ .Number = 5 }}));

    try testing.expectEqual(1, vm.stack.items.len);
    try testing.expect(std.meta.eql(vm.stack.items[0], Value{ .Number = 5 }));

    try vm.stack.append(Value{ .Number = 3.2 });

    try testing.expectEqual(2, vm.stack.items.len);
    try testing.expect(std.meta.eql(vm.stack.items[0], Value{ .Number = 5 }));
    try testing.expect(std.meta.eql(vm.stack.items[1], Value{ .Number = 3.2 }));

    try vm.binary_op(OpCode.Multiply);

    try testing.expectEqual(1, vm.stack.items.len);
    try testing.expect(std.meta.eql(vm.stack.items[0], Value{ .Number = 16 }));

    try vm.stack.append(Value{ .Number = 8.0 });

    try testing.expectEqual(2, vm.stack.items.len);
    try testing.expect(std.meta.eql(vm.stack.items[0], Value{ .Number = 16 }));
    try testing.expect(std.meta.eql(vm.stack.items[1], Value{ .Number = 8 }));

    try vm.binary_op(OpCode.Divide);

    try testing.expectEqual(1, vm.stack.items.len);
    try testing.expect(std.meta.eql(vm.stack.items[0], Value{ .Number = 2 }));
}
