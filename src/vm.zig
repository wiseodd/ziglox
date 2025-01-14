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
const Closure = @import("object.zig").Closure;
const NativeFn = @import("object.zig").NativeFn;
const Native = @import("object.zig").Native;
const String = @import("object.zig").String;
const Upvalue = @import("object.zig").Upvalue;
const Class = @import("object.zig").Class;
const Instance = @import("object.zig").Instance;
const BoundMethod = @import("object.zig").BoundMethod;
const GCAllocator = @import("memory.zig").GCAllocator;
const clock_native = @import("native.zig").clock_native;

const FRAMES_MAX: usize = 64;
const STACK_MAX: usize = FRAMES_MAX * std.math.maxInt(u8);

pub const InterpretError = error{
    CompileError,
    RuntimeError,
};

pub const CallFrame = struct {
    closure: *Closure = undefined,
    ip: [*]u8 = undefined,
    slots: [*]Value = undefined,
};

// WARN: Some GC allocator bug on classes and instances
pub const VirtualMachine = struct {
    allocator: std.mem.Allocator = undefined,
    gc_allocator: GCAllocator = undefined,
    parser: ?*Parser = undefined,
    frames: [FRAMES_MAX]CallFrame = undefined,
    frame_count: usize = undefined,
    stack: [STACK_MAX]Value = undefined,
    stack_top: [*]Value = undefined,
    objects: ?*Obj = undefined, // Linked list of objects (funcs, strs, etc) created
    open_upvalues: ?*Upvalue = undefined,
    strings: std.StringHashMap(*String) = undefined,
    globals: std.StringHashMap(Value) = undefined,
    gray_stack: std.ArrayList(*Obj) = undefined,
    init_string: ?*String = null,

    pub fn init(self: *VirtualMachine, parent_allocator: std.mem.Allocator) !void {
        self.allocator = parent_allocator;
        self.gc_allocator = GCAllocator.init(parent_allocator, self);

        self.parser = null;
        self.frames = undefined;
        self.frame_count = 0;
        self.stack = undefined;
        self.objects = null;
        self.open_upvalues = null;

        const allocator = self.gc_allocator.allocator();
        self.strings = std.StringHashMap(*String).init(allocator);
        self.globals = std.StringHashMap(Value).init(allocator);
        self.gray_stack = std.ArrayList(*Obj).init(allocator);

        self.reset_stack();

        self.init_string = try String.init("init", self);

        // Native functions
        try self.define_native("clock", clock_native);
    }

    pub fn deinit(self: *VirtualMachine) void {
        self.strings.deinit();
        self.globals.deinit();
        self.gray_stack.deinit();
        self.init_string = null;

        var maybe_obj = self.objects;
        while (maybe_obj) |obj| {
            const next = obj.next;
            obj.*.deinit(self);
            maybe_obj = next;
        }
    }

    pub fn interpret(self: *VirtualMachine, source: []const u8) InterpretError!void {
        var parser = Parser.init(self, source) catch {
            return InterpretError.CompileError;
        };
        self.parser = &parser;
        defer self.parser = null;

        const function = try self.parser.?.compile();

        // Put the top-level function into the call frame
        try self.push(Value.from_obj(function.as_obj()));

        const closure = Closure.init(function, self) catch {
            return InterpretError.RuntimeError;
        };
        _ = try self.pop();
        try self.push(Value.from_obj(closure.as_obj()));

        // Call the top-level frame
        try self.call(closure, 0);

        try self.run();
    }

    pub fn push(self: *VirtualMachine, value: Value) InterpretError!void {
        self.stack_top[0] = value;
        self.stack_top += 1;
    }

    pub fn pop(self: *VirtualMachine) InterpretError!Value {
        self.stack_top -= 1;
        return self.stack_top[0];
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

                var val_ptr = self.stack[0..].ptr;
                while (@intFromPtr(val_ptr) < @intFromPtr(self.stack_top)) : (val_ptr += 1) {
                    std.debug.print("[ ", .{});
                    val_ptr[0].print();
                    std.debug.print(" ]", .{});
                }

                std.debug.print("\n", .{});

                // @intFromPtr converts a pointer to its usize address.
                // Since arrays are contiguous, we can compute the distance from the
                // first element.
                const offset: usize = @intFromPtr(frame.ip) - @intFromPtr(frame.closure.function.chunk.code.items.ptr);
                _ = debug.disassemble_instruction(&frame.closure.function.chunk, offset);
            }

            const instruction: OpCode = @enumFromInt(self.read_byte(frame));

            switch (instruction) {
                OpCode.Constant => {
                    const constant: Value = self.read_constant(frame);
                    try self.push(constant);
                },

                OpCode.Nil => try self.push(Value.from_nil()),

                OpCode.True => try self.push(Value.from_boolean(true)),

                OpCode.False => try self.push(Value.from_boolean(false)),

                OpCode.GetProperty => {
                    if (!self.peek(0).is_instance()) {
                        self.runtime_error("Can't get property: only instances have properties.", .{});
                        return InterpretError.RuntimeError;
                    }

                    const inst = self.peek(0).to_obj().as(Instance);
                    const name = try self.read_string(frame);

                    if (inst.fields.get(name)) |value| {
                        _ = try self.pop();
                        try self.push(value);
                    } else {
                        if (!self.bind_method(inst.class, name)) {
                            return InterpretError.RuntimeError;
                        }
                    }
                },

                OpCode.SetProperty => {
                    if (!self.peek(1).is_instance()) {
                        self.runtime_error("Can't set property: only instances have properties.", .{});
                        return InterpretError.RuntimeError;
                    }

                    const inst = self.peek(1).to_obj().as(Instance);

                    inst.fields.put(try self.read_string(frame), self.peek(0)) catch {
                        return InterpretError.RuntimeError;
                    };

                    const value = try self.pop();
                    _ = try self.pop();
                    try self.push(value);
                },

                OpCode.Equal => {
                    const b = try self.pop();
                    const a = try self.pop();
                    try self.push(Value.from_boolean(a.equals(b)));
                },

                OpCode.GetUpvalue => {
                    const slot = self.read_byte(frame);
                    try self.push(frame.closure.upvalues[slot].?.location.*);
                },

                OpCode.SetUpvalue => {
                    const slot = self.read_byte(frame);
                    frame.closure.upvalues[slot].?.location.* = self.peek(0);
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
                        // Use peek instead of pop to keep the strings in the stack
                        // so that the GC won't free them.
                        const str2: []const u8 = self.peek(0).to_obj().as(String).chars;
                        const str1: []const u8 = self.peek(1).to_obj().as(String).chars;

                        var res_chars = self.allocator.alloc(u8, str1.len + str2.len) catch {
                            return InterpretError.RuntimeError;
                        };
                        @memcpy(res_chars[0..str1.len], str1);
                        @memcpy(res_chars[str1.len..], str2);
                        const res_str = String.init(res_chars, self) catch {
                            return InterpretError.RuntimeError;
                        };

                        // Now we can safely pop
                        _ = try self.pop();
                        _ = try self.pop();

                        try self.push(Value.from_obj(res_str.as_obj()));
                    } else if (self.peek(0).is_number() and self.peek(1).is_number()) {
                        const num2: f64 = (try self.pop()).to_number();
                        const num1: f64 = (try self.pop()).to_number();
                        const res_val = Value.from_number(num1 + num2);

                        try self.push(res_val);
                    } else {
                        self.runtime_error("Operands must be two numbers or two strings", .{});
                        return InterpretError.RuntimeError;
                    }
                },

                OpCode.Substract => try self.binary_op(OpCode.Substract),

                OpCode.Multiply => try self.binary_op(OpCode.Multiply),

                OpCode.Divide => try self.binary_op(OpCode.Divide),

                OpCode.Not => try self.push(Value.from_boolean((try self.pop()).is_falsey())),

                OpCode.Negate => {
                    if (self.peek(0).is_number()) {
                        const negated = Value.from_number(-(try self.pop()).to_number());
                        try self.push(negated);
                    } else {
                        self.runtime_error("Operand must be a number.", .{});
                        return InterpretError.RuntimeError;
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

                OpCode.Closure => {
                    const function = self.read_constant(frame).to_obj().as(Function);
                    const closure = Closure.init(function, self) catch {
                        return InterpretError.RuntimeError;
                    };
                    try self.push(Value.from_obj(closure.as_obj()));

                    for (closure.upvalues) |*upvalue| {
                        const is_local = self.read_byte(frame);
                        const index = self.read_byte(frame);

                        if (is_local != 0) {
                            upvalue.* = try self.capture_upvalue(&frame.slots[@intCast(index)]);
                        } else {
                            upvalue.* = frame.closure.upvalues[index];
                        }
                    }
                },

                OpCode.CloseUpvalue => {
                    self.close_upvalue(@ptrCast(self.stack_top - 1));
                    _ = try self.pop();
                },

                OpCode.Return => {
                    const result: Value = try self.pop();
                    self.close_upvalue(@ptrCast(frame.slots));
                    self.frame_count -= 1;

                    if (self.frame_count == 0) {
                        _ = try self.pop();
                        return;
                    }

                    self.stack_top = frame.slots;
                    try self.push(result);
                    frame = &self.frames[self.frame_count - 1];
                },

                OpCode.Class => {
                    const class_name = String.init(try self.read_string(frame), self) catch {
                        return InterpretError.RuntimeError;
                    };
                    const class = Class.init(class_name, self) catch {
                        return InterpretError.RuntimeError;
                    };
                    try self.push(Value.from_obj(class.as_obj()));
                },

                OpCode.Method => try self.define_method(try self.read_string(frame)),

                OpCode.Invoke => {
                    const method_name: []const u8 = try self.read_string(frame);
                    const arg_count: u8 = self.read_byte(frame);

                    try self.invoke(method_name, arg_count);
                    frame = &self.frames[self.frame_count - 1];
                },

                OpCode.Inherit => {
                    if (!self.peek(1).is_class()) {
                        self.runtime_error("Superclass must be a class.", .{});
                    }

                    const superclass = self.peek(1).to_obj().as(Class);
                    const subclass = self.peek(0).to_obj().as(Class);

                    var iter = superclass.methods.iterator();
                    while (iter.next()) |kv| {
                        subclass.methods.put(kv.key_ptr.*, kv.value_ptr.*) catch {
                            return InterpretError.RuntimeError;
                        };
                    }

                    _ = try self.pop();
                },

                OpCode.GetSuper => {
                    const name = try self.read_string(frame);
                    const superclass = (try self.pop()).to_obj().as(Class);

                    if (!self.bind_method(superclass, name)) {
                        return InterpretError.RuntimeError;
                    }
                },

                OpCode.SuperInvoke => {
                    const method_name = try self.read_string(frame);
                    const arg_count = self.read_byte(frame);
                    const superclass = (try self.pop()).to_obj().as(Class);

                    try self.invoke_from_class(superclass, method_name, arg_count);

                    frame = &self.frames[self.frame_count - 1];
                },
            }
        }
    }

    fn peek(self: *VirtualMachine, distance: usize) Value {
        return (self.stack_top - 1 - distance)[0];
    }

    fn call(self: *VirtualMachine, closure: *Closure, arg_count: usize) InterpretError!void {
        if (arg_count != closure.function.arity) {
            self.runtime_error(
                "Expected {d} arguments but got {d}.",
                .{ closure.function.arity, arg_count },
            );
            return InterpretError.RuntimeError;
        }

        if (self.frame_count == FRAMES_MAX) {
            self.runtime_error("Stack overflow.", .{});
            return InterpretError.RuntimeError;
        }

        var frame: *CallFrame = &self.frames[self.frame_count];
        self.frame_count += 1;
        frame.closure = closure;
        frame.ip = closure.function.chunk.code.items.ptr;
        // This points to the last position in the stack before the current frame
        frame.slots = self.stack_top - arg_count - 1;
    }

    fn call_value(self: *VirtualMachine, callee: Value, arg_count: usize) InterpretError!void {
        if (callee.is_obj()) {
            const obj = callee.to_obj();

            switch (obj.obj_type) {
                .Closure => return try self.call(obj.as(Closure), arg_count),

                .Native => {
                    const native_fn = obj.as(Native).function;
                    const result: Value = native_fn(arg_count, self.stack_top[@intFromPtr(self.stack_top) - 1 - arg_count .. @intFromPtr(self.stack_top) - 1].ptr);
                    self.stack_top -= arg_count + 1;
                    self.push(result) catch {
                        return InterpretError.RuntimeError;
                    };
                    return;
                },

                .Class => {
                    const class = obj.as(Class);
                    const inst = Instance.init(class, self) catch {
                        return InterpretError.RuntimeError;
                    };
                    (self.stack_top - arg_count - 1)[0] = Value.from_obj(inst.as_obj());

                    if (class.methods.get(self.init_string.?.chars)) |initializer| {
                        try self.call(initializer.to_obj().as(Closure), arg_count);
                    } else if (arg_count != 0) {
                        // No initializer, but args to the class are provided
                        self.runtime_error("Expected 0 arguments but got {}.", .{arg_count});
                        return InterpretError.RuntimeError;
                    }

                    return;
                },

                .BoundMethod => {
                    const bound = obj.as(BoundMethod);
                    (self.stack_top - arg_count - 1)[0] = bound.receiver;
                    return self.call(bound.method, arg_count);
                },

                else => {},
            }
        }

        self.runtime_error("Can only call functions and classes.", .{});
        return InterpretError.RuntimeError;
    }

    fn invoke_from_class(self: *VirtualMachine, class: *Class, name: []const u8, arg_count: u8) InterpretError!void {
        const method = class.methods.get(name) orelse {
            self.runtime_error("Undefined property '{s}'.", .{name});
            return InterpretError.RuntimeError;
        };

        return self.call(method.to_obj().as(Closure), arg_count);
    }

    fn invoke(self: *VirtualMachine, name: []const u8, arg_count: u8) InterpretError!void {
        const receiver: Value = self.peek(arg_count);

        if (!receiver.is_instance()) {
            self.runtime_error("Only instances have methods.", .{});
            return InterpretError.RuntimeError;
        }

        const instance = receiver.to_obj().as(Instance);

        if (instance.fields.get(name)) |field| {
            (self.stack_top - arg_count - 1)[0] = field;
            return self.call_value(field, arg_count);
        }

        return self.invoke_from_class(instance.class, name, arg_count);
    }

    fn bind_method(self: *VirtualMachine, class: *Class, name: []const u8) bool {
        const method: Value = class.methods.get(name) orelse {
            self.runtime_error("Undefined property '{s}'.", .{name});
            return false;
        };

        const bound = BoundMethod.init(self.peek(0), method.to_obj().as(Closure), self) catch {
            return false;
        };
        _ = self.pop() catch {
            return false;
        };
        self.push(Value.from_obj(bound.as_obj())) catch {
            return false;
        };

        return true;
    }

    fn capture_upvalue(self: *VirtualMachine, local: *Value) InterpretError!*Upvalue {
        var prev_upvalue: ?*Upvalue = null;
        var maybe_upvalue: ?*Upvalue = self.open_upvalues;

        // Search open upvalues linked list
        while (maybe_upvalue) |upvalue| {
            if (@intFromPtr(upvalue.location) <= @intFromPtr(local)) {
                break;
            }

            prev_upvalue = upvalue;
            maybe_upvalue = upvalue.next;
        }

        // Found
        if (maybe_upvalue) |upvalue| {
            if (upvalue.location == local) {
                return upvalue;
            }
        }

        // If not found, insert local as a new element in the list
        const created_upvalue = Upvalue.init(local, self) catch {
            return InterpretError.RuntimeError;
        };
        created_upvalue.next = maybe_upvalue;

        // Insert to the open upvalues linked list
        if (prev_upvalue) |prev| {
            prev.next = created_upvalue;
        } else {
            self.open_upvalues = created_upvalue;
        }

        return created_upvalue;
    }

    fn close_upvalue(self: *VirtualMachine, last: *Value) void {
        while (self.open_upvalues) |upvalue| {
            if (@intFromPtr(upvalue.location) < @intFromPtr(last)) {
                break;
            }

            // Close the upvalue: move it to the heap and refer to its loc
            upvalue.closed = upvalue.location.*;
            upvalue.location = &upvalue.closed;

            self.open_upvalues = upvalue.next;
        }
    }

    fn define_method(self: *VirtualMachine, name: []const u8) InterpretError!void {
        const method: Value = self.peek(0);
        const class = self.peek(1).to_obj().as(Class);
        class.methods.put(name, method) catch {
            return InterpretError.RuntimeError;
        };
        _ = try self.pop();
    }

    fn runtime_error(self: *VirtualMachine, comptime format: []const u8, args: anytype) void {
        std.debug.print(format, args);
        std.debug.print("\n", .{});

        // Print stacktrace
        var i: usize = self.frame_count;

        while (i > 0) {
            i -= 1;

            const frame: CallFrame = self.frames[i];
            const function = frame.closure.function;
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

    fn define_native(self: *VirtualMachine, name: []const u8, function: *const NativeFn) !void {
        // Push then pop immediately so that the GC keeps them alive
        const name_str = try String.init(name, self);
        try self.push(Value.from_obj(name_str.as_obj()));

        const native = try Native.init(function, self);
        const native_val = Value.from_obj(native.as_obj());
        try self.push(native_val);

        try self.globals.put(name, native_val);

        _ = try self.pop();
        _ = try self.pop();
    }

    fn reset_stack(self: *VirtualMachine) void {
        self.stack_top = self.stack[0..];
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
        return frame.closure.function.chunk.constants.items[self.read_byte(frame)];
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
        return self.read_constant(frame).to_obj().as(String).chars;
    }

    inline fn binary_op(self: *VirtualMachine, op: OpCode) InterpretError!void {
        if (!self.peek(0).is_number() or !self.peek(1).is_number()) {
            self.runtime_error("Operands must be numbers.", .{});
            return InterpretError.RuntimeError;
        }

        // The first-popped value is val2 since it's a stack (LIFO)
        const val2 = (try self.pop()).to_number();
        const val1 = (try self.pop()).to_number();

        const res: Value = switch (op) {
            OpCode.Add => Value.form_number(val1 + val2),
            OpCode.Substract => Value.from_number(val1 - val2),
            OpCode.Multiply => Value.from_number(val1 * val2),
            OpCode.Divide => Value.from_number(val1 / val2),
            OpCode.Greater => Value.from_boolean(val1 > val2),
            OpCode.Less => Value.from_boolean(val1 < val2),
            else => return InterpretError.RuntimeError,
        };
        try self.push(res);
    }
};
