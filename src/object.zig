const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const VirtualMachine = @import("vm.zig").VirtualMachine;
const Value = @import("value.zig").Value;
const Chunk = @import("chunk.zig").Chunk;
const flags = @import("flags.zig");
const mem = @import("memory.zig");

pub const ObjType = enum {
    Function,
    Closure,
    Native,
    String,
    Upvalue,
    Class,
    Instance,
    BoundMethod,
};

// For function pointer to a native func
pub const NativeFn = fn (usize, [*]Value) Value;

pub const Obj = struct {
    obj_type: ObjType,
    next: ?*Obj,
    is_marked: bool,

    /// The reason we do `ptr = allocator.create(T); ptr.* = ...` is so that
    /// the newly initialized object lives in the heap. Otherwise, we will
    /// have an undefined behavior (use-after-free).
    pub fn init(vm: *VirtualMachine, comptime T: type, obj_type: ObjType) !*Obj {
        const ptr = try vm.gc_allocator.allocator().create(T);

        ptr.obj = Obj{
            .obj_type = obj_type,
            .next = vm.objects,
            .is_marked = false,
        };

        vm.objects = &ptr.obj;

        if (flags.DEBUG_LOG_GC) {
            std.debug.print(
                "{*} ({s}) allocate {d} for {s}\n",
                .{ &ptr.obj, @tagName(ptr.obj.obj_type), @sizeOf(T), @tagName(obj_type) },
            );
        }

        return &ptr.obj;
    }

    pub fn deinit(self: *Obj, vm: *VirtualMachine) void {
        if (flags.DEBUG_LOG_GC) {
            std.debug.print("{*} free type {s}\n", .{ self, @tagName(self.obj_type) });
        }

        switch (self.obj_type) {
            .String => self.as(String).deinit(vm),
            .Function => self.as(Function).deinit(vm),
            .Closure => self.as(Closure).deinit(vm),
            .Native => self.as(Native).deinit(vm),
            .Upvalue => self.as(Upvalue).deinit(vm),
            .Class => self.as(Class).deinit(vm),
            .Instance => self.as(Instance).deinit(vm),
            .BoundMethod => self.as(BoundMethod).deinit(vm),
        }
    }

    pub fn print(self: *Obj) void {
        switch (self.obj_type) {
            .String => self.as(String).print(),
            .Function => self.as(Function).print(),
            .Closure => self.as(Closure).print(),
            .Native => self.as(Native).print(),
            .Upvalue => self.as(Upvalue).print(),
            .Class => self.as(Class).print(),
            .Instance => self.as(Instance).print(),
            .BoundMethod => self.as(BoundMethod).print(),
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

        try vm.push(Value.from_obj(str.as_obj()));
        _ = try vm.pop();

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
    upvalue_count: usize,
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
            .upvalue_count = 0,
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

pub const Closure = struct {
    obj: Obj,
    upvalues: []?*Upvalue,
    upvalue_count: usize,
    function: *Function,

    pub fn init(function: *Function, vm: *VirtualMachine) !*Closure {
        const upvalues = try vm.allocator.alloc(?*Upvalue, function.upvalue_count);
        for (upvalues) |*upvalue| {
            upvalue.* = null;
        }

        const obj = try Obj.init(vm, Closure, .Closure);
        const closure = obj.as(Closure);

        closure.* = Closure{
            .obj = obj.*,
            .function = function,
            .upvalues = upvalues,
            .upvalue_count = function.upvalue_count,
        };

        return closure;
    }

    pub fn deinit(self: *Closure, vm: *VirtualMachine) void {
        vm.allocator.free(self.upvalues);
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

pub const Upvalue = struct {
    obj: Obj,
    location: *Value,
    next: ?*Upvalue,
    closed: Value,

    pub fn init(slot: *Value, vm: *VirtualMachine) !*Upvalue {
        const obj = try Obj.init(vm, Upvalue, .Upvalue);
        const upvalue = obj.as(Upvalue);

        upvalue.* = Upvalue{
            .obj = obj.*,
            .location = slot,
            .next = null,
            .closed = Value.from_nil(),
        };

        return upvalue;
    }

    pub fn deinit(self: *Upvalue, vm: *VirtualMachine) void {
        vm.allocator.destroy(self);
    }

    pub inline fn as_obj(self: *Upvalue) *Obj {
        return @ptrCast(self);
    }

    pub fn print(self: *const Upvalue) void {
        _ = self;
        return;
    }

    pub fn println(self: *const Upvalue) void {
        self.print();
        std.debug.print("\n", .{});
    }
};

pub const Class = struct {
    obj: Obj,
    name: *String,
    methods: std.StringHashMap(Value),

    pub fn init(name: *String, vm: *VirtualMachine) !*Class {
        const obj = try Obj.init(vm, Class, .Class);
        const class = obj.as(Class);

        class.* = Class{
            .obj = obj.*,
            .name = name,
            .methods = std.StringHashMap(Value).init(vm.gc_allocator.allocator()),
        };

        return class;
    }

    pub fn deinit(self: *Class, vm: *VirtualMachine) void {
        // TODO: bug with GC!
        self.methods.deinit();
        vm.allocator.destroy(self);
    }

    pub inline fn as_obj(self: *Class) *Obj {
        return @ptrCast(self);
    }

    pub fn print(self: *const Class) void {
        std.debug.print("[{s}]", .{self.name.chars});
    }

    pub fn println(self: *const Class) void {
        self.print();
        std.debug.print("\n", .{});
    }
};

pub const Instance = struct {
    obj: Obj,
    class: *Class,
    fields: std.StringHashMap(Value),

    pub fn init(class: *Class, vm: *VirtualMachine) !*Instance {
        const obj = try Obj.init(vm, Instance, .Instance);
        const inst = obj.as(Instance);

        inst.* = Instance{
            .obj = obj.*,
            .class = class,
            .fields = std.StringHashMap(Value).init(vm.gc_allocator.allocator()),
        };

        return inst;
    }

    pub fn deinit(self: *Instance, vm: *VirtualMachine) void {
        self.fields.deinit();
        vm.allocator.destroy(self);
    }

    pub inline fn as_obj(self: *Instance) *Obj {
        return @ptrCast(self);
    }

    pub fn print(self: *const Instance) void {
        std.debug.print("Instance of: [{s}]", .{self.class.name.chars});
    }

    pub fn println(self: *const Instance) void {
        self.print();
        std.debug.print("\n", .{});
    }
};

pub const BoundMethod = struct {
    obj: Obj,
    receiver: Value,
    method: *Closure,

    pub fn init(receiver: Value, method: *Closure, vm: *VirtualMachine) !*BoundMethod {
        const obj = try Obj.init(vm, BoundMethod, .BoundMethod);
        const bm = obj.as(BoundMethod);

        bm.* = BoundMethod{
            .obj = obj.*,
            .receiver = receiver,
            .method = method,
        };

        return bm;
    }

    pub fn deinit(self: *BoundMethod, vm: *VirtualMachine) void {
        vm.allocator.destroy(self);
    }

    pub inline fn as_obj(self: *BoundMethod) *Obj {
        return @ptrCast(self);
    }

    pub fn print(self: *const BoundMethod) void {
        self.method.function.print();
    }

    pub fn println(self: *const BoundMethod) void {
        self.print();
        std.debug.print("\n", .{});
    }
};
