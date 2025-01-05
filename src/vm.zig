const std = @import("std");
const testing = std.testing;
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const Value = @import("value.zig").Value;
const debug = @import("debug.zig");
const flags = @import("flags.zig");
const Parser = @import("compiler.zig").Parser;
const Obj = @import("object.zig").Obj;
const Function = @import("object.zig").Function;
const String = @import("object.zig").String;

const FRAMES_MAX: usize = 64;
const STACK_MAX: usize = FRAMES_MAX * std.math.maxInt(u8);

pub const InterpretError = error{
    CompileError,
    RuntimeError,
};

pub const CallFrame = struct {
    function: *Function = undefined,
    ip: [*]u8 = undefined,
    slots: [*]Value = undefined,
};

pub const VirtualMachine = struct {
    allocator: std.mem.Allocator,
    frames: [FRAMES_MAX]CallFrame,
    frame_count: usize,
    stack: [STACK_MAX]Value,
    stack_top: [*]Value = undefined,
    stack_top_idx: usize = 0,
    objects: ?*Obj, // Linked list of objects (funcs, strs, etc) created
    strings: std.StringHashMap(Value),
    globals: std.StringHashMap(Value),

    pub fn init(allocator: std.mem.Allocator) *VirtualMachine {
        var vm = VirtualMachine{
            .allocator = allocator,
            .frames = undefined,
            .frame_count = 0,
            .stack = undefined,
            .objects = null,
            .strings = std.StringHashMap(Value).init(allocator),
            .globals = std.StringHashMap(Value).init(allocator),
        };

        vm.reset_stack();

        return &vm;
    }

    pub fn deinit(self: *VirtualMachine) void {
        self.strings.deinit();
        self.globals.deinit();
    }

    pub fn interpret(self: *VirtualMachine, source: []const u8) InterpretError!void {
        var parser = Parser.init(self, source) catch {
            return InterpretError.CompileError;
        };
        const function = try parser.compile();

        // Put the top-level function into the call frame
        try self.push(Value.obj(function.as_obj()));

        // Call the top-level frame
        try self.call(function, 0);

        try self.run();
    }

    fn run(self: *VirtualMachine) InterpretError!void {
        if (flags.DEBUG_TRACE_EXECUTION) {
            std.debug.print("\n", .{});
        }

        var frame: *CallFrame = &self.frames[self.frame_count - 1];

        // Note that self.read_byte() advances the pointer
        while (true) {
            if (flags.DEBUG_TRACE_EXECUTION) {
                std.debug.print("          ", .{});

                var val_ptr = self.stack_top - 1;
                while (@intFromPtr(val_ptr) >= @intFromPtr(self.stack[0..])) : (val_ptr -= 1) {
                    std.debug.print("[ ", .{});
                    val_ptr[0].print();
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
                        const str2: []const u8 = (try self.pop()).Obj.as(String).chars;
                        const str1: []const u8 = (try self.pop()).Obj.as(String).chars;

                        var res_chars = self.allocator.alloc(u8, str1.len + str2.len) catch {
                            return InterpretError.RuntimeError;
                        };
                        @memcpy(res_chars[0..str1.len], str1);
                        @memcpy(res_chars[str1.len..], str2);
                        const res_str = String.init(res_chars, self) catch {
                            return InterpretError.RuntimeError;
                        };

                        try self.push(Value.obj(res_str.as_obj()));
                    } else if (self.peek(0).is_number() and self.peek(1).is_number()) {
                        const num2: f64 = (try self.pop()).Number;
                        const num1: f64 = (try self.pop()).Number;
                        const res_val = Value.number(num1 + num2);

                        try self.push(res_val);
                    } else {
                        self.runtime_error("Operands must be two numbers or two strings", .{});
                        return InterpretError.RuntimeError;
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

                OpCode.Print => (try self.pop()).println(),

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

                OpCode.Call => {
                    const arg_count: u8 = self.read_byte(frame);
                    try self.call_value(self.peek(arg_count), arg_count);
                    frame = &self.frames[self.frame_count - 1];
                },

                OpCode.Return => {
                    const result: Value = try self.pop();
                    self.frame_count -= 1;

                    if (self.frame_count == 0) {
                        _ = try self.pop();
                        return;
                    }

                    self.stack_top = frame.slots;
                    try self.push(result);
                    frame = &self.frames[self.frame_count - 1];
                },
            }
        }
    }

    fn push(self: *VirtualMachine, value: Value) InterpretError!void {
        self.stack_top[0] = value;
        self.stack_top += 1;
        self.stack_top_idx += 1;
    }

    fn pop(self: *VirtualMachine) InterpretError!Value {
        self.stack_top -= 1;
        self.stack_top_idx -= 1;
        return self.stack_top[0];
    }

    fn peek(self: *VirtualMachine, distance: usize) Value {
        return (self.stack_top - 1 - distance)[0];
    }

    fn call(self: *VirtualMachine, function: *Function, arg_count: usize) InterpretError!void {
        if (arg_count != function.arity) {
            self.runtime_error(
                "Expected {d} arguments but got {d}.",
                .{ function.arity, arg_count },
            );
            return InterpretError.RuntimeError;
        }

        if (self.frame_count == FRAMES_MAX) {
            self.runtime_error("Stack overflow.", .{});
            return InterpretError.RuntimeError;
        }

        var frame: *CallFrame = &self.frames[self.frame_count];
        frame.function = function;
        frame.ip = function.chunk.code.items.ptr;
        // This points to the last position in the stack before the current frame
        frame.slots = self.stack_top - arg_count - 1;

        self.frame_count += 1;
    }

    fn call_value(self: *VirtualMachine, callee: Value, arg_count: usize) InterpretError!void {
        if (callee.is_obj()) {
            return try self.call(callee.Obj.as(Function), arg_count);
        }

        self.runtime_error("Can only call functions and classes.", .{});
        return InterpretError.RuntimeError;
    }

    fn runtime_error(self: *VirtualMachine, comptime format: []const u8, args: anytype) void {
        std.debug.print(format, args);
        std.debug.print("\n", .{});

        // Print stacktrace
        var i: usize = self.frame_count;

        while (i > 0) {
            i -= 1;

            const frame: CallFrame = self.frames[i];
            const function = frame.function;
            const instruction: usize = @intFromPtr(frame.ip) - @intFromPtr(function.chunk.code.items.ptr);
            std.debug.print("[line {}] in ", .{function.chunk.lines.items[instruction]});

            if (function.name) |name| {
                std.debug.print("{s}()\n", .{name.chars});
            } else {
                std.debug.print("script\n", .{});
            }
        }

        self.reset_stack();
    }

    pub fn reset_stack(self: *VirtualMachine) void {
        self.stack_top = self.stack[0..];
        self.stack_top_idx = 0;
        self.frame_count = 0;
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
        return (msb << @intCast(8)) | lsb;
    }

    inline fn read_string(self: *VirtualMachine, frame: *CallFrame) InterpretError![]const u8 {
        return self.read_constant(frame).Obj.as(String).chars;
    }

    inline fn binary_op(self: *VirtualMachine, op: OpCode) InterpretError!void {
        if (!self.peek(0).is_number() or !self.peek(1).is_number()) {
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
