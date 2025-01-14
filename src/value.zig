const std = @import("std");
const testing = std.testing;
const Obj = @import("object.zig").Obj;
const ObjType = @import("object.zig").ObjType;
const String = @import("object.zig").String;
const Function = @import("object.zig").Function;
const flags = @import("flags.zig");

pub const Value = if (flags.NAN_BOXING) NaNBoxedValue else UnionValue;
pub const ValueArray = std.ArrayList(Value);

const NaNBoxedValue = packed struct {
    const SIGN_BIT: u64 = 0x8000000000000000;
    const QNAN: u64 = 0x7ffc000000000000;

    const TAG_NIL: u64 = 1;
    const TAG_FALSE: u64 = 2;
    const TAG_TRUE: u64 = 3;

    const NIL_VAL: u64 = QNAN | TAG_NIL;
    const FALSE_VAL: u64 = QNAN | TAG_FALSE;
    const TRUE_VAL: u64 = QNAN | TAG_TRUE;

    data: u64,

    pub fn print(self: NaNBoxedValue) void {
        if (self.is_boolean()) {
            std.debug.print("{}", .{self.to_boolean()});
        } else if (self.is_nil()) {
            std.debug.print("nil", .{});
        } else if (self.is_number()) {
            std.debug.print("{}", .{self.to_number()});
        } else if (self.is_obj()) {
            self.to_obj().print();
        }
    }

    pub fn println(self: NaNBoxedValue) void {
        self.print();
        std.debug.print("\n", .{});
    }

    pub fn equals(self: NaNBoxedValue, other: NaNBoxedValue) bool {
        if (self.is_number() and other.is_number()) {
            return self.to_number() == other.to_number();
        }

        return self.data == other.data;
    }

    pub inline fn is_falsey(self: NaNBoxedValue) bool {
        if (self.is_nil()) return true;
        if (self.is_boolean()) return !self.to_boolean();

        return false;
    }

    pub inline fn from_boolean(value: bool) NaNBoxedValue {
        return NaNBoxedValue{ .data = if (value) TRUE_VAL else FALSE_VAL };
    }

    pub inline fn from_number(value: f64) NaNBoxedValue {
        return NaNBoxedValue{ .data = @bitCast(value) };
    }

    pub inline fn from_obj(value: *Obj) NaNBoxedValue {
        const addr: u64 = @bitCast(@intFromPtr(value));
        return NaNBoxedValue{ .data = (SIGN_BIT | QNAN | addr) };
    }

    pub inline fn from_nil() NaNBoxedValue {
        return NaNBoxedValue{ .data = (QNAN | TAG_NIL) };
    }

    pub inline fn to_boolean(self: NaNBoxedValue) bool {
        return self.data == TRUE_VAL;
    }

    pub inline fn to_number(self: NaNBoxedValue) f64 {
        return @bitCast(self.data);
    }

    pub inline fn to_obj(self: NaNBoxedValue) *Obj {
        const ptr_int: usize = @bitCast(self.data & ~(SIGN_BIT | QNAN));
        return @ptrFromInt(ptr_int);
    }

    pub inline fn to_nil(self: NaNBoxedValue) ?void {
        _ = self;
        return null;
    }

    pub inline fn is_boolean(self: NaNBoxedValue) bool {
        return (self.data | 1) == TRUE_VAL;
    }

    pub inline fn is_number(self: NaNBoxedValue) bool {
        return (self.data & QNAN) != QNAN;
    }

    pub inline fn is_obj(self: NaNBoxedValue) bool {
        return (self.data & (QNAN | SIGN_BIT)) == (QNAN | SIGN_BIT);
    }

    pub inline fn is_string(self: NaNBoxedValue) bool {
        return self.is_obj() and self.to_obj().obj_type == .String;
    }

    pub inline fn is_function(self: NaNBoxedValue) bool {
        return self.is_obj() and self.to_obj().obj_type == .Function;
    }

    pub inline fn is_closure(self: NaNBoxedValue) bool {
        return self.is_obj() and self.to_obj().obj_type == .Closure;
    }

    pub inline fn is_native(self: NaNBoxedValue) bool {
        return self.is_obj() and self.to_obj().obj_type == .Native;
    }

    pub inline fn is_upvalue(self: NaNBoxedValue) bool {
        return self.is_obj() and self.to_obj().obj_type == .Upvalue;
    }

    pub inline fn is_class(self: NaNBoxedValue) bool {
        return self.is_obj() and self.to_obj().obj_type == .Class;
    }

    pub inline fn is_instance(self: NaNBoxedValue) bool {
        return self.is_obj() and self.to_obj().obj_type == .Instance;
    }

    pub inline fn is_bound_method(self: NaNBoxedValue) bool {
        return self.is_obj() and self.to_obj().obj_type == .BoundMethod;
    }

    pub inline fn is_nil(self: NaNBoxedValue) bool {
        return self.data == NIL_VAL;
    }
};

const UnionValue = union(enum) {
    Bool: bool,
    Number: f64,
    Obj: *Obj,
    Nil: void,

    pub fn print(self: UnionValue) void {
        switch (self) {
            .Bool => |val| std.debug.print("{}", .{val}),
            .Number => |val| std.debug.print("{d}", .{val}),
            .Obj => |val| val.print(),
            .Nil => std.debug.print("nil", .{}),
        }
    }

    pub fn println(self: UnionValue) void {
        self.print();
        std.debug.print("\n", .{});
    }

    pub fn equals(self: UnionValue, other: UnionValue) bool {
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

    pub inline fn is_falsey(self: UnionValue) bool {
        if (self.is_nil()) return true;

        return switch (self) {
            .Bool => |val| !val,
            else => false,
        };
    }

    pub inline fn from_boolean(value: bool) UnionValue {
        return UnionValue{ .Bool = value };
    }

    pub inline fn from_number(value: f64) UnionValue {
        return UnionValue{ .Number = value };
    }

    pub inline fn from_obj(value: *Obj) UnionValue {
        return UnionValue{ .Obj = value };
    }

    pub inline fn from_nil() UnionValue {
        return UnionValue{ .Nil = {} };
    }

    pub inline fn to_boolean(self: UnionValue) bool {
        return self.Bool;
    }

    pub inline fn to_number(self: UnionValue) f64 {
        return self.Number;
    }

    pub inline fn to_obj(self: UnionValue) *Obj {
        return self.Obj;
    }

    pub inline fn to_nil(self: UnionValue) undefined {
        return self.Nil;
    }

    pub inline fn is_boolean(self: UnionValue) bool {
        return switch (self) {
            .Bool => true,
            else => false,
        };
    }

    pub inline fn is_number(self: UnionValue) bool {
        return switch (self) {
            .Number => true,
            else => false,
        };
    }

    pub inline fn is_obj(self: UnionValue) bool {
        return switch (self) {
            .Obj => true,
            else => false,
        };
    }

    pub inline fn is_string(self: UnionValue) bool {
        return self.is_obj() and self.to_obj().obj_type == .String;
    }

    pub inline fn is_function(self: UnionValue) bool {
        return self.is_obj() and self.to_obj().obj_type == .Function;
    }

    pub inline fn is_closure(self: UnionValue) bool {
        return self.is_obj() and self.to_obj().obj_type == .Closure;
    }

    pub inline fn is_native(self: UnionValue) bool {
        return self.is_obj() and self.to_obj().obj_type == .Native;
    }

    pub inline fn is_upvalue(self: UnionValue) bool {
        return self.is_obj() and self.to_obj().obj_type == .Upvalue;
    }

    pub inline fn is_class(self: UnionValue) bool {
        return self.is_obj() and self.to_obj().obj_type == .Class;
    }

    pub inline fn is_instance(self: UnionValue) bool {
        return self.is_obj() and self.to_obj().obj_type == .Instance;
    }

    pub inline fn is_bound_method(self: UnionValue) bool {
        return self.is_obj() and self.to_obj().obj_type == .BoundMethod;
    }

    pub inline fn is_nil(self: UnionValue) bool {
        return switch (self) {
            .Nil => true,
            else => false,
        };
    }
};
