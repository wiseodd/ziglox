const std = @import("std");
const InterpretError = @import("vm.zig").InterpretError;
const Scanner = @import("scanner.zig").Scanner;
const Token = @import("token.zig").Token;

pub fn compile(source: []const u8) InterpretError!void {
    var scanner = Scanner.init(source);
    var line: usize = 0;

    while (true) {
        const token: Token = scanner.scan();

        if (token.line != line) {
            std.debug.print("{: >4}  ", .{token.line});
            line = token.line;
        } else {
            std.debug.print("   |  ", .{});
        }

        std.debug.print("{s: >12}  '{s}'\n", .{ @tagName(token.token_type), token.start[0..token.length] });

        if (token.token_type == .EOF) break;
    }
}
