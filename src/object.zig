const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

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
    obj: Obj,
    chars: []const u8,

    pub fn init(allocator: Allocator, chars: []const u8) !String {
        return String{
            .obj = Obj.init(ObjType.String),
            .chars = try allocator.dupe(u8, chars),
        };
    }

    pub fn print(self: *String) void {
        std.debug.print("{s}", .{self.chars});
    }
};

test "string_init" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    const str = String{ .obj = Obj{ .obj_type = ObjType.String }, .chars = "asd" };
    const str2 = try String.init(allocator, str.chars);
    try testing.expectEqual(true, str2.obj.obj_type == ObjType.String);
    try testing.expect(std.mem.eql(u8, str.chars, str2.chars));
}
