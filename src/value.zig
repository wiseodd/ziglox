const std = @import("std");
const testing = std.testing;
const Obj = @import("object.zig").Obj;
const ObjType = @import("object.zig").ObjType;
const String = @import("object.zig").String;
const Function = @import("object.zig").Function;

const ValueError = error{
    CastError,
};

pub const ValueArray = std.ArrayList(Value);

pub const Value = union(enum) {
    Bool: bool,
    Number: f64,
    Obj: *Obj,
    Nil: void,

    pub fn print(self: Value) void {
        switch (self) {
            .Bool => |val| std.debug.print("{}", .{val}),
            .Number => |val| std.debug.print("{d}", .{val}),
            .Obj => |val| val.print(),
            .Nil => std.debug.print("nil", .{}),
        }
    }

    pub fn println(self: Value) void {
        self.print();
        std.debug.print("\n", .{});
    }

    pub fn equals(self: Value, other: Value) bool {
        const all_bools = self.is_boolean() and other.is_boolean();
        const all_nums = self.is_number() and other.is_number();
        const all_string = self.is_string() and other.is_string();
        const all_nils = self.is_nil() and other.is_nil();

        if (!all_bools and !all_nums and !all_string and !all_nils) {
            return false;
        }

        return switch (self) {
            .Bool => self.Bool == other.Bool,
            .Number => self.Number == other.Number,
            .Obj => String.eq(self.Obj.as(String), other.Obj.as(String)),
            .Nil => true,
        };
    }

    pub inline fn is_falsey(self: Value) bool {
        if (self.is_nil()) return true;

        return switch (self) {
            .Bool => |val| !val,
            else => false,
        };
    }

    pub inline fn boolean(value: bool) Value {
        return Value{ .Bool = value };
    }

    pub inline fn number(value: f64) Value {
        return Value{ .Number = value };
    }

    pub inline fn obj(value: *Obj) Value {
        return Value{ .Obj = value };
    }

    pub inline fn nil() Value {
        return Value{ .Nil = {} };
    }

    pub inline fn is_boolean(self: Value) bool {
        return switch (self) {
            .Bool => true,
            else => false,
        };
    }

    pub inline fn is_number(self: Value) bool {
        return switch (self) {
            .Number => true,
            else => false,
        };
    }

    pub inline fn is_obj(self: Value) bool {
        return switch (self) {
            .Obj => true,
            else => false,
        };
    }

    pub inline fn is_string(self: Value) bool {
        return self.is_obj() and self.Obj.obj_type == .String;
    }

    pub inline fn is_function(self: Value) bool {
        return self.is_obj() and self.Obj.obj_type == .Function;
    }

    pub inline fn is_closure(self: Value) bool {
        return self.is_obj() and self.Obj.obj_type == .Closure;
    }

    pub inline fn is_native(self: Value) bool {
        return self.is_obj() and self.Obj.obj_type == .Native;
    }

    pub inline fn is_upvalue(self: Value) bool {
        return self.is_obj() and self.Obj.obj_type == .Upvalue;
    }

    pub inline fn is_nil(self: Value) bool {
        return switch (self) {
            .Nil => true,
            else => false,
        };
    }
};
