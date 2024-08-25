const std = @import("std");
const expect = std.testing.expect;
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const Value = @import("value.zig").Value;
const print_value = @import("value.zig").print_value;
const debug = @import("debug.zig");
const flags = @import("flags.zig");

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
            .chunk = undefined,
            .ip = undefined,
            .stack = std.ArrayList(Value).init(allocator),
        };
    }

    pub fn deinit(self: *VirtualMachine) void {
        self.stack.deinit();
    }

    pub fn interpret(self: *VirtualMachine, chunk: Chunk) InterpretError!Value {
        self.chunk = chunk;
        // Initialize self.ip with the pointers of the slice/array.
        self.ip = chunk.code.items.ptr;
        return self.run();
    }

    fn run(self: *VirtualMachine) InterpretError!Value {
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
                OpCode.OpConstant => {
                    const constant: Value = self.read_constant();
                    self.stack.append(constant) catch {
                        return InterpretError.RuntimeError;
                    };
                },
                OpCode.OpAdd => try self.binary_op(OpCode.OpAdd),
                OpCode.OpSubstract => try self.binary_op(OpCode.OpSubstract),
                OpCode.OpMultiply => try self.binary_op(OpCode.OpMultiply),
                OpCode.OpDivide => try self.binary_op(OpCode.OpDivide),
                OpCode.OpNegate => {
                    self.stack.append(-self.stack.pop()) catch {
                        return InterpretError.RuntimeError;
                    };
                },
                OpCode.OpReturn => {
                    const retval: Value = self.stack.pop();

                    if (flags.DEBUG_TRACE_EXECUTION) {
                        print_value(retval);
                        std.debug.print("\n", .{});
                    }

                    return retval;
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
            OpCode.OpAdd => val1 + val2,
            OpCode.OpSubstract => val1 - val2,
            OpCode.OpMultiply => val1 * val2,
            OpCode.OpDivide => val1 / val2,
            else => return InterpretError.RuntimeError,
        };
        self.stack.append(res) catch {
            return InterpretError.RuntimeError;
        };
    }
};

fn test_init_chunk(chunk: *Chunk) !void {
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
}

test "vm_init" {
    const allocator = std.testing.allocator;
    var vm = VirtualMachine.init(allocator);
    defer vm.deinit();

    try expect(vm.stack.items.len == 0);
}

test "vm_run" {
    const allocator = std.testing.allocator;
    var vm = VirtualMachine.init(allocator);
    var chunk = Chunk.init(allocator);
    defer vm.deinit();
    defer chunk.deinit();

    try test_init_chunk(&chunk);

    const result: Value = try vm.interpret(chunk);
    try expect(result == -0.8214285714285714);
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

    const expectations = [_]OpCode{ OpCode.OpConstant, OpCode.OpConstant, OpCode.OpAdd };

    for (expectations) |exp| {
        const instruction: OpCode = @enumFromInt(vm.read_byte());
        try expect(instruction == exp);
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
        try expect(constant == exp);
    }
}

test "vm_binary_op" {
    const allocator = std.testing.allocator;
    var vm = VirtualMachine.init(allocator);
    defer vm.deinit();

    try vm.stack.append(6);
    try vm.stack.append(3);
    try expect(std.mem.eql(Value, vm.stack.items, &[2]Value{ 6, 3 }));

    try vm.binary_op(OpCode.OpAdd);
    try expect(std.mem.eql(Value, vm.stack.items, &[1]Value{9}));

    try vm.stack.append(4);
    try expect(std.mem.eql(Value, vm.stack.items, &[2]Value{ 9, 4 }));
    try vm.binary_op(OpCode.OpSubstract);
    try expect(std.mem.eql(Value, vm.stack.items, &[1]Value{5}));

    try vm.stack.append(3.2);
    try expect(std.mem.eql(Value, vm.stack.items, &[2]Value{ 5, 3.2 }));
    try vm.binary_op(OpCode.OpMultiply);
    try expect(std.mem.eql(Value, vm.stack.items, &[1]Value{16}));

    try vm.stack.append(8.0);
    try expect(std.mem.eql(Value, vm.stack.items, &[2]Value{ 16, 8 }));
    try vm.binary_op(OpCode.OpDivide);
    try expect(std.mem.eql(Value, vm.stack.items, &[1]Value{2}));
}
