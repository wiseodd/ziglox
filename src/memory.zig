const std = @import("std");
const flags = @import("flags.zig");
const VirtualMachine = @import("vm.zig").VirtualMachine;
const Value = @import("value.zig").Value;
const ValueArray = @import("value.zig").ValueArray;
const Obj = @import("object.zig").Obj;
const Upvalue = @import("object.zig").Upvalue;
const Function = @import("object.zig").Function;
const Closure = @import("object.zig").Closure;
const Parser = @import("compiler.zig").Parser;
const Compiler = @import("compiler.zig").Compiler;

const GC_HEAP_GROW_FACTOR: usize = 2;

pub fn collect_garbage(vm: *VirtualMachine) void {
    var size_before: usize = undefined;

    if (flags.DEBUG_LOG_GC) {
        std.debug.print("-- gc begin\n", .{});
        size_before = vm.bytes_allocated;
    }

    mark_roots(vm);
    trace_references(vm);
    // sweep(vm); // TODO: Buggy!

    vm.next_gc = vm.bytes_allocated * GC_HEAP_GROW_FACTOR;

    if (flags.DEBUG_LOG_GC) {
        std.debug.print("-- gc end\n", .{});
        std.debug.print(
            "   collected {} bytes (from {} to {}), next at {}\n",
            .{ size_before - vm.bytes_allocated, size_before, vm.bytes_allocated, vm.next_gc },
        );
    }
}

fn mark_roots(vm: *VirtualMachine) void {
    var slot: [*]Value = &vm.stack;
    while (@intFromPtr(slot) < @intFromPtr(vm.stack_top)) : (slot += 1) {
        mark_value(slot[0]);

        for (vm.frames[0..vm.frame_count]) |frame| {
            mark_object(frame.closure.as_obj());
        }

        var maybe_upvalue = vm.open_upvalues;
        while (maybe_upvalue) |upvalue| : (maybe_upvalue = upvalue.next) {
            mark_object(upvalue.as_obj());
        }
    }

    mark_table(&vm.globals);
    mark_compiler_roots(vm.parser);
}

fn mark_compiler_roots(maybe_parser: ?*Parser) void {
    if (maybe_parser) |parser| {
        var maybe_compiler: ?*Compiler = parser.current_compiler;
        while (maybe_compiler) |compiler| : (maybe_compiler = compiler.enclosing) {
            mark_object(compiler.function.as_obj());
        }
    }
}

fn mark_table(table: *std.StringHashMap(Value)) void {
    var iter = table.iterator();
    while (iter.next()) |kv| {
        mark_value(kv.value_ptr.*);
    }
}

fn mark_value(value: Value) void {
    if (value.is_obj()) {
        mark_object(value.Obj);
    }
}

fn mark_object(maybe_obj: ?*Obj) void {
    if (maybe_obj) |obj| {
        if (obj.is_marked) return;

        if (flags.DEBUG_LOG_GC) {
            std.debug.print("{*} mark ", .{obj});
            obj.println();
        }

        obj.is_marked = true;
    }
}

fn mark_array(array: []Value) void {
    for (array) |value| {
        mark_value(value);
    }
}

fn trace_references(vm: *VirtualMachine) void {
    while (vm.gray_stack.items.len > 0) {
        const obj = vm.gray_stack.pop();
        blacken_object(obj);
    }
}

fn blacken_object(obj: *Obj) void {
    if (flags.DEBUG_LOG_GC) {
        std.debug.print("{*} blacken ", .{obj});
        obj.println();
    }

    switch (obj.obj_type) {
        .Upvalue => mark_value(obj.as(Upvalue).closed),
        .Function => {
            const function = obj.as(Function);
            if (function.name) |name| mark_object(name.as_obj());
            mark_array(function.chunk.constants.items);
        },
        .Closure => {
            const closure = obj.as(Closure);
            mark_object(closure.function.as_obj());

            for (closure.upvalues[0..closure.upvalue_count]) |maybe_upvalue| {
                if (maybe_upvalue) |upvalue| {
                    mark_object(upvalue.as_obj());
                }
            }
        },
        else => {},
    }
}

fn sweep(vm: *VirtualMachine) void {
    var maybe_prev: ?*Obj = null;
    var maybe_obj: ?*Obj = vm.objects;

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
                vm.objects = maybe_obj;
            }

            // Free up the unreachable obj
            unreached.deinit(vm);
        }
    }
}
