const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const VirtualMachine = @import("vm.zig").VirtualMachine;
const Value = @import("value.zig").Value;
const Chunk = @import("chunk.zig").Chunk;

pub const ObjType = enum {
    Function,
    String,
};

pub const FunctionType = enum {
    Function,
    Script,
};

pub const Obj = struct {
    allocator: Allocator,
    obj_type: ObjType,
    next: ?*Obj,

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

    pub fn print(self: *Obj) void {
        switch (self.obj_type) {
            .Function => self.as(Function).print(),
            .String => self.as(String).print(),
        }
    }

    pub inline fn is(self: *Obj, obj_type: ObjType) bool {
        return self.obj_type == obj_type;
    }

    pub inline fn as(self: *Obj, comptime T: type) *T {
        return @fieldParentPtr("obj", self);
    }
};

pub const Function = struct {
    obj: Obj,
    arity: usize,
    chunk: Chunk,
    name: ?*String,

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

pub const String = struct {
    obj: Obj,
    chars: []const u8,

    pub fn init(chars: []const u8, vm: *VirtualMachine) !*String {
        const obj = try Obj.init(vm, String, .String);
        const str = obj.as(String);

        str.* = String{ .obj = obj.*, .chars = chars };

        return str;
    }

    pub fn deinit(self: String) void {
        self.allocator.free(self.chars);
    }

    pub inline fn as_obj(self: *String) *Obj {
        return @ptrCast(self);
    }

    pub fn print(self: *const String) void {
        std.debug.print("{s}", .{self.chars});
    }

    pub fn println(self: *const Function) void {
        self.print();
        std.debug.print("\n", .{});
    }

    pub fn eq(self: *const String, other: *const String) bool {
        return std.mem.eql(u8, self.chars, other.chars);
    }
};
