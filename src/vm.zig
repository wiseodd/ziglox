const std = @import("std");
const testing = std.testing;
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const Value = @import("value.zig").Value;
const debug = @import("debug.zig");
const flags = @import("flags.zig");
const Parser = @import("compiler.zig").Parser;
const Function = @import("object.zig").Function;
const String = @import("object.zig").String;

const FRAMES_MAX: usize = 64;
const STACK_MAX: usize = FRAMES_MAX * std.math.maxInt(u8);

pub const InterpretError = error{
    CompileError,
    RuntimeError,
};

pub const CallFrame = struct {
    function: *Function,
    ip: [*]u8,
    slots: [*]Value,

    pub fn init(function: *Function, ip: [*]u8, slots: [*]Value) CallFrame {
        return CallFrame{
            .function = function,
            .ip = ip,
            .slots = slots,
        };
    }
};

pub const VirtualMachine = struct {
    allocator: std.mem.Allocator,
    frames: std.ArrayList(CallFrame),
    stack: std.ArrayList(Value),
    strings: std.StringHashMap(Value),
    globals: std.StringHashMap(Value),

    pub fn init(allocator: std.mem.Allocator) VirtualMachine {
        return VirtualMachine{
            .allocator = allocator,
            .frames = std.ArrayList(CallFrame).init(allocator),
            .stack = std.ArrayList(Value).init(allocator),
            .strings = std.StringHashMap(Value).init(allocator),
            .globals = std.StringHashMap(Value).init(allocator),
        };
    }

    pub fn deinit(self: *VirtualMachine) void {
        self.frames.deinit();
        self.stack.deinit();
        self.strings.deinit();
        self.globals.deinit();
    }

    pub fn interpret(self: *VirtualMachine, source: []const u8) InterpretError!void {
        var parser = try Parser.init(self.allocator, source, &self.strings);
        const function: *Function = try parser.compile();

        // Put the top-level function into the call frame
        try self.push(Value.function(function));
        const frame = CallFrame.init(
            function,
            function.chunk.code.items.ptr,
            self.stack.items.ptr,
        );
        self.frames.append(frame) catch {
            return InterpretError.RuntimeError;
        };

        try self.run();
    }

    fn run(self: *VirtualMachine) InterpretError!void {
        const frame: *CallFrame = @constCast(&self.frames.getLast());

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
                const offset: usize = @intFromPtr(frame.ip) - @intFromPtr(frame.function.chunk.code.items.ptr);
                _ = debug.disassemble_instruction(&frame.function.chunk, offset);
            }

            const instruction: OpCode = @enumFromInt(self.read_byte(frame));

            switch (instruction) {
                OpCode.Constant => {
                    const constant: Value = self.read_constant(frame);
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
                    const slot: usize = @intCast(self.read_byte(frame));
                    try self.push(frame.slots[slot]);
                },
                OpCode.SetLocal => {
                    const slot: usize = @intCast(self.read_byte(frame));
                    frame.slots[slot] = self.peek(0);
                },
                OpCode.GetGlobal => {
                    const name: []const u8 = try self.read_string(frame);

                    if (self.globals.get(name)) |value| {
                        try self.push(value);
                    } else {
                        self.runtime_error("Undefined variable '{s}'.", .{name});
                        return InterpretError.RuntimeError;
                    }
                },
                OpCode.DefineGlobal => {
                    const name: []const u8 = try self.read_string(frame);
                    self.globals.put(name, self.peek(0)) catch {
                        return InterpretError.RuntimeError;
                    };
                    _ = try self.pop();
                },
                OpCode.SetGlobal => {
                    const name: []const u8 = try self.read_string(frame);

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
                OpCode.Jump => {
                    const offset: usize = self.read_short(frame);
                    frame.ip += offset;
                },
                OpCode.JumpIfFalse => {
                    const offset: usize = self.read_short(frame);

                    // Jump (moving the instruction pointer more than 1 step) if the
                    // top value in the stack is falsey. Note that this top value
                    // corresponds to the condition in `if (condition) { statement }`.
                    // If `condition` is falsey, then we skip the statement, i.e. jump
                    // over it.
                    if (self.peek(0).is_falsey()) {
                        frame.ip += offset;
                    }
                },
                OpCode.Loop => {
                    const offset: usize = self.read_short(frame);
                    // Jump backward to the start of the loop.
                    frame.ip -= offset;
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

        const frame: *CallFrame = @constCast(&self.frames.getLast());

        // Distance between the current pointer to the beginning.
        // Note that there's `- 1` there because `self.ip` has been advanced by one
        // when an instruction is read via `self.read_byte()`.
        const instruction: usize = @intFromPtr(frame.ip) - @intFromPtr(frame.function.chunk.code.items.ptr) - 1;
        const line: usize = frame.function.chunk.lines.items[instruction];
        std.debug.print("[Line {}] in script\n", .{line});

        self.reset_stack();
    }

    pub fn reset_stack(self: *VirtualMachine) void {
        self.stack.deinit();
        self.stack = std.ArrayList(Value).init(self.allocator);
    }

    // Inline function to emulate C macro
    inline fn read_byte(self: *VirtualMachine, frame: *CallFrame) u8 {
        _ = self;

        // ip is a many-item pointer.
        // The first element points to start of the slice.
        const value: u8 = frame.ip[0];
        // Pointer arithmetic below. We advance the ip to the pointer of the next
        // element in the slice.
        frame.ip += 1;
        return value;
    }

    inline fn read_constant(self: *VirtualMachine, frame: *CallFrame) Value {
        return frame.function.chunk.constants.items[self.read_byte(frame)];
    }

    inline fn read_short(self: *VirtualMachine, frame: *CallFrame) usize {
        _ = self;

        // Skip over the jump operand (the 2 bytes indicating how much jump).
        frame.ip += 2;

        // Recall in the compiler, `self.ip[-2]` encodes the 8 most significant bytes
        // while `self.ip[-1]` the least. What we're doing here is to combine them
        // into a u16. Note that we use pointer arithmetic to do the indexing.
        const msb: usize = @intCast((frame.ip - 2)[0]);
        const lsb: usize = @intCast((frame.ip - 1)[0]);
        return msb << @intCast(8) | lsb;
    }

    inline fn read_string(self: *VirtualMachine, frame: *CallFrame) InterpretError![]const u8 {
        switch (self.read_constant(frame)) {
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
