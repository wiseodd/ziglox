const std = @import("std");
const flags = @import("flags.zig");
const VirtualMachine = @import("vm.zig").VirtualMachine;
const Value = @import("value.zig").Value;
const Obj = @import("object.zig").Obj;
const Parser = @import("compiler.zig").Parser;
const Compiler = @import("compiler.zig").Compiler;

pub fn collect_garbage(vm: *VirtualMachine) void {
    if (flags.DEBUG_LOG_GC) {
        std.debug.print("-- gc begin\n", .{});
    }

    mark_roots(vm);

    if (flags.DEBUG_LOG_GC) {
        std.debug.print("-- gc end\n", .{});
    }
}

pub fn mark_object(maybe_obj: ?*Obj) void {
    if (maybe_obj) |obj| {
        obj.is_marked = true;

        if (flags.DEBUG_LOG_GC) {
            std.debug.print("{*} mark ", .{obj});
            obj.println();
        }
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

fn mark_value(value: Value) void {
    if (value.is_obj()) {
        mark_object(value.Obj);
    }
}

fn mark_table(table: *std.StringHashMap(Value)) void {
    var iter = table.iterator();
    while (iter.next()) |kv| {
        mark_value(kv.value_ptr.*);
    }
}

fn mark_compiler_roots(maybe_parser: ?*Parser) void {
    if (maybe_parser) |parser| {
        var maybe_compiler: ?*Compiler = parser.current_compiler;
        while (maybe_compiler) |compiler| : (maybe_compiler = compiler.enclosing) {
            mark_object(compiler.function.as_obj());
        }
    }
}
