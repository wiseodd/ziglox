const std = @import("std");
const testing = std.testing;
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const Value = @import("value.zig").Value;
const debug = @import("debug.zig");
const flags = @import("flags.zig");
const Parser = @import("compiler.zig").Parser;
const String = @import("object.zig").String;

pub const InterpretError = error{
    CompileError,
    RuntimeError,
};

pub const VirtualMachine = struct {
    allocator: std.mem.Allocator,
    chunk: Chunk,
    ip: [*]u8,
    stack: std.ArrayList(Value),
    strings: std.StringHashMap(Value),
    globals: std.StringHashMap(Value),

    pub fn init(allocator: std.mem.Allocator) VirtualMachine {
        return VirtualMachine{
            .allocator = allocator,
            .chunk = Chunk.init(allocator),
            .ip = undefined,
            .stack = std.ArrayList(Value).init(allocator),
            .strings = std.StringHashMap(Value).init(allocator),
            .globals = std.StringHashMap(Value).init(allocator),
        };
    }

    pub fn deinit(self: *VirtualMachine) void {
        self.chunk.deinit();
        self.stack.deinit();
        self.strings.deinit();
        self.globals.deinit();
    }

    pub fn interpret(self: *VirtualMachine, source: []const u8) InterpretError!void {
        var parser = Parser.init(self.allocator, source, &self.chunk, &self.strings);
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
                    slot.print();
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
                    try self.push(constant);
                },
                OpCode.Nil => try self.push(Value.nil()),
                OpCode.True => try self.push(Value.boolean(true)),
                OpCode.False => try self.push(Value.boolean(false)),
                OpCode.Equal => {
                    const b = try self.pop();
                    const a = try self.pop();
                    try self.push(Value.boolean(a.equals(b)));
                },
                OpCode.Pop => _ = try self.pop(),
                OpCode.GetLocal => {
                    const slot: usize = @intCast(self.read_byte());
                    try self.push(self.stack.items[slot]);
                },
                OpCode.SetLocal => {
                    const slot: usize = @intCast(self.read_byte());
                    self.stack.items[slot] = self.peek(0);
                },
                OpCode.GetGlobal => {
                    const name: []const u8 = try self.read_string();

                    if (self.globals.get(name)) |value| {
                        try self.push(value);
                    } else {
                        self.runtime_error("Undefined variable '{s}'.", .{name});
                        return InterpretError.RuntimeError;
                    }
                },
                OpCode.DefineGlobal => {
                    const name: []const u8 = try self.read_string();
                    self.globals.put(name, self.peek(0)) catch {
                        return InterpretError.RuntimeError;
                    };
                    _ = try self.pop();
                },
                OpCode.SetGlobal => {
                    const name: []const u8 = try self.read_string();

                    if (!self.globals.contains(name)) {
                        self.runtime_error("Undefined variable '{s}'", .{name});
                        return InterpretError.RuntimeError;
                    }

                    self.globals.put(name, self.peek(0)) catch {
                        return InterpretError.RuntimeError;
                    };
                },
                OpCode.Greater => try self.binary_op(OpCode.Greater),
                OpCode.Less => try self.binary_op(OpCode.Less),
                OpCode.Add => {
                    if (self.peek(0).is_string() and self.peek(1).is_string()) {
                        const str2: []const u8 = (try self.pop()).String.chars;
                        const str1: []const u8 = (try self.pop()).String.chars;

                        var res_chars = self.allocator.alloc(u8, str1.len + str2.len) catch {
                            return InterpretError.RuntimeError;
                        };
                        @memcpy(res_chars[0..str1.len], str1);
                        @memcpy(res_chars[str1.len..], str2);
                        const res_val = Value.string(
                            self.allocator,
                            res_chars,
                            &self.strings,
                        ) catch {
                            return InterpretError.RuntimeError;
                        };

                        try self.push(res_val);
                    } else if (self.peek(0).is_number() and self.peek(1).is_number()) {
                        const num2: f64 = (try self.pop()).Number;
                        const num1: f64 = (try self.pop()).Number;
                        const res_val = Value.number(num1 + num2);

                        try self.push(res_val);
                    } else {
                        self.runtime_error("Operands must be two numbers or two strings", .{});
                    }
                },
                OpCode.Substract => try self.binary_op(OpCode.Substract),
                OpCode.Multiply => try self.binary_op(OpCode.Multiply),
                OpCode.Divide => try self.binary_op(OpCode.Divide),
                OpCode.Not => try self.push(Value.boolean((try self.pop()).is_falsey())),
                OpCode.Negate => {
                    switch (self.peek(0)) {
                        .Number => {
                            const negated = Value.number(-(try self.pop()).Number);
                            try self.push(negated);
                        },
                        else => {
                            self.runtime_error("Operand must be a number.", .{});
                            return InterpretError.RuntimeError;
                        },
                    }
                },
                OpCode.Print => {
                    const value: Value = try self.pop();
                    value.print();
                    std.debug.print("\n", .{});
                },
                OpCode.Return => {
                    return;
                },
            }
        }
    }

    fn push(self: *VirtualMachine, value: Value) InterpretError!void {
        self.stack.append(value) catch {
            return InterpretError.RuntimeError;
        };
    }

    fn pop(self: *VirtualMachine) InterpretError!Value {
        if (self.stack.items.len == 0) {
            return InterpretError.RuntimeError;
        }

        return self.stack.pop();
    }

    fn peek(self: *VirtualMachine, distance: usize) Value {
        return self.stack.items[self.stack.items.len - 1 - distance];
    }

    fn runtime_error(self: *VirtualMachine, comptime format: []const u8, args: anytype) void {
        std.debug.print(format, args);
        std.debug.print("\n", .{});

        // Distance between the current pointer to the beginning.
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

    inline fn read_string(self: *VirtualMachine) InterpretError![]const u8 {
        switch (self.read_constant()) {
            .String => |val| return val.chars,
            else => return InterpretError.RuntimeError,
        }
    }

    inline fn binary_op(self: *VirtualMachine, op: OpCode) InterpretError!void {
        if (self.peek(0) != Value.Number or self.peek(1) != Value.Number) {
            self.runtime_error("Operands must be numbers.", .{});
            return InterpretError.RuntimeError;
        }

        // The first-popped value is val2 since it's a stack (LIFO)
        const val2 = (try self.pop()).Number;
        const val1 = (try self.pop()).Number;

        const res: Value = switch (op) {
            OpCode.Add => Value.number(val1 + val2),
            OpCode.Substract => Value.number(val1 - val2),
            OpCode.Multiply => Value.number(val1 * val2),
            OpCode.Divide => Value.number(val1 / val2),
            OpCode.Greater => Value.boolean(val1 > val2),
            OpCode.Less => Value.boolean(val1 < val2),
            else => return InterpretError.RuntimeError,
        };
        try self.push(res);
    }
};
