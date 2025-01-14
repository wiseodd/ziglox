const std = @import("std");
const flags = @import("flags.zig");
const VirtualMachine = @import("vm.zig").VirtualMachine;
const Value = @import("value.zig").Value;
const ValueArray = @import("value.zig").ValueArray;
const Obj = @import("object.zig").Obj;
const Upvalue = @import("object.zig").Upvalue;
const Function = @import("object.zig").Function;
const Closure = @import("object.zig").Closure;
const Class = @import("object.zig").Class;
const Instance = @import("object.zig").Instance;
const BoundMethod = @import("object.zig").BoundMethod;
const Parser = @import("compiler.zig").Parser;
const Compiler = @import("compiler.zig").Compiler;
const Allocator = std.mem.Allocator;

// TODO: Bug in class/instance GC
pub const GCAllocator = struct {
    const GC_HEAP_GROW_FACTOR: usize = 2;

    parent_allocator: Allocator,
    vm: *VirtualMachine,
    bytes_allocated: usize,
    next_gc: usize,

    pub fn init(parent_allocator: Allocator, vm: *VirtualMachine) GCAllocator {
        return .{
            .parent_allocator = parent_allocator,
            .vm = vm,
            .bytes_allocated = 0,
            .next_gc = if (flags.DEBUG_STRESS_GC) 1 else (1024 * 1024),
        };
    }

    pub fn allocator(self: *GCAllocator) Allocator {
        return Allocator{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        const self: *GCAllocator = @ptrCast(@alignCast(ctx));

        if (self.bytes_allocated + len > self.next_gc) {
            self.collect_garbage();
        }

        self.bytes_allocated += len;

        return self.parent_allocator.vtable.alloc(self.parent_allocator.ptr, len, ptr_align, ret_addr);
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
        const self: *GCAllocator = @ptrCast(@alignCast(ctx));

        if (new_len > buf.len) {
            if (self.bytes_allocated + (new_len - buf.len) > self.next_gc) {
                self.collect_garbage();
            }
        }

        if (self.parent_allocator.vtable.resize(self.parent_allocator.ptr, buf, buf_align, new_len, ret_addr)) {
            if (new_len > buf.len) {
                self.bytes_allocated += new_len - buf.len;
            } else {
                self.bytes_allocated -= buf.len - new_len;
            }
            return true;
        } else {
            return false;
        }
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
        const self: *GCAllocator = @ptrCast(@alignCast(ctx));

        self.parent_allocator.vtable.free(self.parent_allocator.ptr, buf, buf_align, ret_addr);
        self.bytes_allocated -= buf.len;
    }

    fn collect_garbage(self: *GCAllocator) void {
        var size_before: usize = undefined;

        if (flags.DEBUG_LOG_GC) {
            std.debug.print("-- gc begin\n", .{});
            size_before = self.bytes_allocated;
        }

        self.mark_roots();
        self.trace_references();
        self.sweep();

        self.next_gc = self.bytes_allocated * GC_HEAP_GROW_FACTOR;

        if (flags.DEBUG_LOG_GC) {
            std.debug.print("-- gc end\n", .{});
            std.debug.print(
                "   collected {} bytes (from {} to {}), next at {}\n",
                .{ self.bytes_allocated - size_before, size_before, self.bytes_allocated, self.next_gc },
            );
        }
    }

    fn mark_roots(self: *GCAllocator) void {
        var slot: [*]Value = &self.vm.stack;
        while (@intFromPtr(slot) < @intFromPtr(self.vm.stack_top)) : (slot += 1) {
            self.mark_value(slot[0]);
        }

        for (self.vm.frames[0..self.vm.frame_count]) |frame| {
            self.mark_object(frame.closure.as_obj());
        }

        var maybe_upvalue = self.vm.open_upvalues;
        while (maybe_upvalue) |upvalue| : (maybe_upvalue = upvalue.next) {
            self.mark_object(upvalue.as_obj());
        }

        self.mark_table(&self.vm.globals);
        self.mark_compiler_roots();

        if (self.vm.init_string) |init_str| {
            self.mark_object(init_str.as_obj());
        }
    }

    fn mark_compiler_roots(self: *GCAllocator) void {
        const parser = self.vm.parser orelse return;

        var maybe_compiler: ?*Compiler = parser.current_compiler;
        while (maybe_compiler) |compiler| : (maybe_compiler = compiler.enclosing) {
            self.mark_object(compiler.function.as_obj());
        }
    }

    fn mark_table(self: *GCAllocator, table: *std.StringHashMap(Value)) void {
        var iter = table.iterator();
        while (iter.next()) |kv| {
            self.mark_value(kv.value_ptr.*);
        }
    }

    fn mark_value(self: *GCAllocator, value: Value) void {
        if (value.is_obj()) {
            self.mark_object(value.to_obj());
        }
    }

    fn mark_object(self: *GCAllocator, maybe_obj: ?*Obj) void {
        const obj = maybe_obj orelse return;

        if (obj.is_marked) return;

        if (flags.DEBUG_LOG_GC) {
            std.debug.print("{*} ({s}) mark ", .{ obj, @tagName(obj.obj_type) });
            obj.println();
        }

        obj.is_marked = true;

        // Crash the program if we can't even allocate memory for GC
        self.vm.gray_stack.append(obj) catch {
            std.process.exit(1);
        };
    }

    fn mark_array(self: *GCAllocator, array: []Value) void {
        for (array) |value| {
            self.mark_value(value);
        }
    }

    fn trace_references(self: *GCAllocator) void {
        while (self.vm.gray_stack.items.len > 0) {
            const obj = self.vm.gray_stack.pop();
            self.blacken_object(obj);
        }
    }

    /// Keep objects in the heap alive
    fn blacken_object(self: *GCAllocator, obj: *Obj) void {
        if (flags.DEBUG_LOG_GC) {
            std.debug.print("{*} ({s}) blacken ", .{ obj, @tagName(obj.obj_type) });
            obj.println();
        }

        switch (obj.obj_type) {
            .Upvalue => self.mark_value(obj.as(Upvalue).closed),

            .Function => {
                const function = obj.as(Function);
                if (function.name) |name| self.mark_object(name.as_obj());
                self.mark_array(function.chunk.constants.items);
            },

            .Closure => {
                const closure = obj.as(Closure);
                self.mark_object(closure.function.as_obj());

                for (closure.upvalues[0..closure.upvalue_count]) |maybe_upvalue| {
                    if (maybe_upvalue) |upvalue| {
                        self.mark_object(upvalue.as_obj());
                    }
                }
            },

            .Class => {
                const class = obj.as(Class);
                self.mark_object(class.name.as_obj());
                self.mark_table(&class.methods);
            },

            .Instance => {
                const inst = obj.as(Instance);
                self.mark_object(inst.class.as_obj());
                self.mark_table(&inst.fields);
            },

            .BoundMethod => {
                const bound = obj.as(BoundMethod);
                self.mark_value(bound.receiver);
                self.mark_object(bound.method.as_obj());
            },

            .String, .Native => {},
        }
    }

    fn sweep(self: *GCAllocator) void {
        var maybe_prev: ?*Obj = null;
        var maybe_obj: ?*Obj = self.vm.objects;

        while (maybe_obj) |obj| {
            if (obj.is_marked) {
                // Remove the color for the next time we do GC
                obj.is_marked = false;

                // Ignore marked -- reachable
                maybe_prev = obj;
                maybe_obj = obj.next;
            } else {
                const unreached = obj;

                // Unlink obj from the objects linked list
                maybe_obj = obj.next;
                if (maybe_prev) |prev| {
                    prev.next = maybe_obj;
                } else {
                    self.vm.objects = maybe_obj;
                }

                // Free up the unreachable obj
                unreached.deinit(self.vm);
            }
        }
    }
};
