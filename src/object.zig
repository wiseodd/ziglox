const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const VirtualMachine = @import("vm.zig").VirtualMachine;
const Value = @import("value.zig").Value;
const Chunk = @import("chunk.zig").Chunk;

pub const ObjType = enum {
    Function,
    Closure,
    Native,
    String,
};

pub const FunctionType = enum {
    Function,
    Script,
};

// For function pointer to a native func
pub const NativeFn = fn (usize, [*]Value) Value;

pub const Obj = struct {
    allocator: Allocator,
    obj_type: ObjType,
    next: ?*Obj,

    /// The reason we do `ptr = allocator.create(T); ptr.* = ...` is so that
    /// the newly initialized object lives in the heap. Otherwise, we will
    /// have an undefined behavior (use-after-free).
    pub fn init(vm: *VirtualMachine, comptime T: type, obj_type: ObjType) !*Obj {
        const ptr = try vm.allocator.create(T);

        ptr.obj = Obj{
            .allocator = vm.allocator,
            .obj_type = obj_type,
            .next = vm.objects,
        };

        vm.objects = &ptr.obj;

        return &ptr.obj;
    }

    pub fn deinit(self: *Obj, vm: *VirtualMachine) void {
        switch (self.obj_type) {
            .String => self.as(String).deinit(vm),
            .Function => self.as(Function).deinit(vm),
            .Closure => self.as(Closure).deinit(vm),
            .Native => self.as(Native).deinit(vm),
        }
    }

    pub fn print(self: *Obj) void {
        switch (self.obj_type) {
            .String => self.as(String).print(),
            .Function => self.as(Function).print(),
            .Closure => self.as(Closure).print(),
            .Native => self.as(Native).print(),
        }
    }

    pub fn println(self: *Obj) void {
        self.print();
        std.debug.print("\n", .{});
    }

    pub inline fn is(self: *Obj, obj_type: ObjType) bool {
        return self.obj_type == obj_type;
    }

    pub inline fn as(self: *Obj, comptime T: type) *T {
        return @fieldParentPtr("obj", self);
    }
};

pub const String = struct {
    obj: Obj,
    chars: []const u8,

    /// The reason we do `ptr = allocator.create(T); ptr.* = ...` is so that
    /// the newly initialized object lives in the heap. Otherwise, we will
    /// have an undefined behavior (use-after-free).
    pub fn init(chars: []const u8, vm: *VirtualMachine) !*String {
        const obj = try Obj.init(vm, String, .String);
        const str = obj.as(String);

        var chars_cpy = try vm.allocator.alloc(u8, chars.len);
        @memcpy(chars_cpy[0..chars.len], chars);

        str.* = String{
            .obj = obj.*,
            .chars = chars_cpy,
        };

        return str;
    }

    pub fn deinit(self: *String, vm: *VirtualMachine) void {
        vm.allocator.free(self.chars);
        vm.allocator.destroy(self);
    }

    pub inline fn as_obj(self: *String) *Obj {
        return @ptrCast(self);
    }

    pub fn print(self: *const String) void {
        std.debug.print("{s}", .{self.chars});
    }

    pub fn println(self: *const String) void {
        self.print();
        std.debug.print("\n", .{});
    }

    pub fn eq(self: *const String, other: *const String) bool {
        return std.mem.eql(u8, self.chars, other.chars);
    }
};

pub const Function = struct {
    obj: Obj,
    arity: usize,
    chunk: Chunk,
    name: ?*String,

    /// The reason we do `ptr = allocator.create(T); ptr.* = ...` is so that
    /// the newly initialized object lives in the heap. Otherwise, we will
    /// have an undefined behavior (use-after-free).
    pub fn init(vm: *VirtualMachine) !*Function {
        const obj = try Obj.init(vm, Function, .Function);
        const func = obj.as(Function);

        func.* = Function{
            .obj = obj.*,
            .arity = 0,
            .chunk = Chunk.init(vm.allocator),
            .name = null,
        };

        return func;
    }

    pub fn deinit(self: *Function, vm: *VirtualMachine) void {
        self.chunk.deinit();
        vm.allocator.destroy(self);
    }

    pub inline fn as_obj(self: *Function) *Obj {
        return @ptrCast(self);
    }

    pub fn print(self: *const Function) void {
        if (self.name) |name| {
            std.debug.print("<fn {s}>", .{name.chars});
        } else {
            std.debug.print("<script>", .{});
        }
    }

    pub fn println(self: *const Function) void {
        self.print();
        std.debug.print("\n", .{});
    }
};

pub const Closure = struct {
    obj: Obj,
    function: *Function,

    pub fn init(function: *Function, vm: *VirtualMachine) !*Closure {
        const obj = try Obj.init(vm, Closure, .Closure);
        const closure = obj.as(Closure);

        closure.* = Closure{
            .obj = obj.*,
            .function = function,
        };

        return closure;
    }

    pub fn deinit(self: *Closure, vm: *VirtualMachine) void {
        vm.allocator.destroy(self);
    }

    pub inline fn as_obj(self: *Closure) *Obj {
        return @ptrCast(self);
    }

    pub fn print(self: *const Closure) void {
        self.function.print();
    }

    pub fn println(self: *const Closure) void {
        self.print();
        std.debug.print("\n", .{});
    }
};

pub const Native = struct {
    obj: Obj,
    function: *const NativeFn,

    pub fn init(function: *const NativeFn, vm: *VirtualMachine) !*Native {
        const obj = try Obj.init(vm, Native, .Native);
        const native = obj.as(Native);

        native.* = Native{
            .obj = obj.*,
            .function = function,
        };

        return native;
    }

    pub fn deinit(self: *Native, vm: *VirtualMachine) void {
        vm.allocator.destroy(self);
    }

    pub inline fn as_obj(self: *Native) *Obj {
        return @ptrCast(self);
    }

    pub fn print(self: *const Native) void {
        _ = self;
        std.debug.print("<native fn>", .{});
    }

    pub fn println(self: *const Native) void {
        self.print();
        std.debug.print("\n", .{});
    }
};
