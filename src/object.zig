const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Value = @import("value.zig").Value;

pub const ObjType = enum {
    String,
};

pub const Obj = struct {
    obj_type: ObjType,

    pub fn init(obj_type: ObjType) Obj {
        return Obj{
            .obj_type = obj_type,
        };
    }

    pub inline fn is_obj_type(self: *Obj, obj_type: ObjType) bool {
        return self.obj_type == obj_type;
    }
};

pub const String = struct {
    allocator: Allocator,
    obj: Obj,
    chars: []const u8,

    pub fn init(allocator: Allocator, chars: []const u8, table: *std.StringHashMap(Value)) !String {
        // For string interning.
        // Return the stored strings if the char-array arg has been defined before.
        var char_copy: []const u8 = undefined;

        if (table.getKey(chars)) |key| {
            char_copy = key;
        } else {
            // Automatically store a string in the VM's hashmap whenever one is allocated.
            // This way it can be used later if the user allocates the same char-array.
            char_copy = try allocator.dupe(u8, chars);
            try table.put(char_copy, Value.nil());
        }

        return String{
            .allocator = allocator,
            .obj = Obj.init(ObjType.String),
            .chars = char_copy,
        };
    }

    pub fn deinit(self: String) void {
        self.allocator.free(self.chars);
    }

    pub fn print(self: *String) void {
        std.debug.print("{s}", .{self.chars});
    }
};

test "string_init" {
    const allocator = testing.allocator;

    const str1 = try String.init(allocator, "Hello World!");
    defer str1.deinit();

    const str2 = try String.init(allocator, str1.chars);
    defer str2.deinit();

    try testing.expectEqual(true, str2.obj.obj_type == ObjType.String);
    try testing.expect(std.mem.eql(u8, str1.chars, str2.chars));
}
