const std = @import("std");
const testing = std.testing;
const InterpretError = @import("vm.zig").InterpretError;
const Scanner = @import("scanner.zig").Scanner;
const Token = @import("token.zig").Token;
const TokenType = @import("token.zig").TokenType;
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const Value = @import("value.zig").Value;
const FLAGS = @import("flags.zig");
const debug = @import("debug.zig");

// Lowest to highest --- the ordering here implies
// the ordering in the members' ordinal values `@intFromEnum(Precedence.Member)`.
// Hence we can compare precedence like so `@intFromEnum(.Term) > @intFromEnum(.Or)`.
const Precedence = enum {
    None,
    Assignment, // =
    Or, // or
    And, // and
    Equality, // ==
    Comparison, // < > <= >=
    Term, // + -
    Factor, // * /
    Unary, // ! -
    Call, // . ()
    Primary,
};

pub const Parser = struct {
    // Type alias for parser functions (`unary`, `binary`, etc.)
    const ParseFn = fn (*Parser) void;

    // Rule for parsing
    const ParseRule = struct {
        prefix: ?*const ParseFn = null,
        infix: ?*const ParseFn = null,
        precedence: Precedence = .None,
    };

    // Type alias
    const ParseRules = std.EnumArray(TokenType, ParseRule);

    source: []const u8,
    scanner: Scanner,
    compiling_chunk: *Chunk,
    current: Token = undefined,
    previous: Token = undefined,
    had_error: bool = false,
    panic_mode: bool = false,
    // We build a static parse rules table here and access it through pointers.
    // It's more efficient than having a function that return a new `ParseRule` each time.
    parse_rules: ParseRules = ParseRules.init(.{
        .LeftParen = ParseRule{ .prefix = grouping, .infix = null, .precedence = Precedence.None },
        .RightParen = ParseRule{},
        .LeftBrace = ParseRule{},
        .RightBrace = ParseRule{},
        .Comma = ParseRule{},
        .Dot = ParseRule{},
        .Minus = ParseRule{ .prefix = unary, .infix = binary, .precedence = Precedence.Term },
        .Plus = ParseRule{ .prefix = null, .infix = binary, .precedence = Precedence.Term },
        .SemiColon = ParseRule{},
        .Slash = ParseRule{ .prefix = null, .infix = binary, .precedence = Precedence.Term },
        .Star = ParseRule{ .prefix = null, .infix = binary, .precedence = Precedence.Term },
        .Bang = ParseRule{ .prefix = unary, .infix = null, .precedence = Precedence.None },
        .BangEqual = ParseRule{ .prefix = null, .infix = binary, .precedence = Precedence.Equality },
        .Equal = ParseRule{},
        .EqualEqual = ParseRule{ .prefix = null, .infix = binary, .precedence = Precedence.Equality },
        .Greater = ParseRule{ .prefix = null, .infix = binary, .precedence = Precedence.Comparison },
        .GreaterEqual = ParseRule{ .prefix = null, .infix = binary, .precedence = Precedence.Comparison },
        .Less = ParseRule{ .prefix = null, .infix = binary, .precedence = Precedence.Comparison },
        .LessEqual = ParseRule{ .prefix = null, .infix = binary, .precedence = Precedence.Comparison },
        .Identifier = ParseRule{},
        .String = ParseRule{},
        .Number = ParseRule{ .prefix = number, .infix = null, .precedence = Precedence.None },
        .And = ParseRule{},
        .Class = ParseRule{},
        .Else = ParseRule{},
        .False = ParseRule{ .prefix = literal, .infix = null, .precedence = Precedence.None },
        .For = ParseRule{},
        .Fun = ParseRule{},
        .If = ParseRule{},
        .Nil = ParseRule{ .prefix = literal, .infix = null, .precedence = Precedence.None },
        .Or = ParseRule{},
        .Print = ParseRule{},
        .Return = ParseRule{},
        .Super = ParseRule{},
        .This = ParseRule{},
        .True = ParseRule{ .prefix = literal, .infix = null, .precedence = Precedence.None },
        .Var = ParseRule{},
        .While = ParseRule{},
        .Error = ParseRule{},
        .EOF = ParseRule{},
    }),

    pub fn init(source: []const u8, chunk: *Chunk) Parser {
        return Parser{
            .source = source,
            .scanner = Scanner.init(source),
            .compiling_chunk = chunk,
        };
    }

    pub fn compile(self: *Parser) InterpretError!void {
        self.advance();
        self.expression();
        self.consume(TokenType.EOF, "Expect end of expression.");
        self.end_compiler();

        if (self.had_error) return InterpretError.CompileError;
    }

    fn advance(self: *Parser) void {
        self.previous = self.current;

        while (true) {
            self.current = self.scanner.scan();

            if (self.current.token_type != TokenType.Error) {
                break;
            }

            self.err_at_current(self.current.start[0..self.current.length]);
        }
    }

    fn consume(self: *Parser, token_type: TokenType, message: []const u8) void {
        if (self.current.token_type == token_type) {
            self.advance();
        } else {
            self.err_at_current(message);
        }
    }

    fn end_compiler(self: *Parser) void {
        self.emit_return();

        if (FLAGS.DEBUG_PRINT_CODE) {
            if (!self.had_error) {
                debug.disasemble_chunk(self.current_chunk(), "code");
            }
        }
    }

    fn expression(self: *Parser) void {
        // Compile all expressions that have higher or equal level of precedence
        // than assignment `=` (the lowest precedence level).
        self.parse_precedence(Precedence.Assignment);
    }

    fn grouping(self: *Parser) void {
        // The left paren has been consumed, so we can directly
        // evaluate the expression inside the grouping recursively
        self.expression();
        self.consume(TokenType.RightParen, "Expect ')' after expression.");
    }

    fn number(self: *Parser) void {
        const lexeme: []const u8 = self.previous.start[0..self.previous.length];
        const val: f64 = std.fmt.parseFloat(f64, lexeme) catch {
            self.err("Invalid number string.");
            return;
        };
        self.emit_constant(Value{ .Number = val });
    }

    fn unary(self: *Parser) void {
        // The unary operator type
        const operator_type = self.previous.token_type;

        // Compile the operand recursively
        self.parse_precedence(Precedence.Unary);

        // Emit the operator instruction.
        // This is done after emitting the expression even though the source
        // code is written operator-first e.g. `-(2 + 3)` because our VM is a stack.
        // I.e. we want to pop `5` first, then negeate it, then push the result.
        switch (operator_type) {
            TokenType.Bang => self.emit_byte(@intFromEnum(OpCode.Not)),
            TokenType.Minus => self.emit_byte(@intFromEnum(OpCode.Negate)),
            else => return, // Unreacable
        }
    }

    fn binary(self: *Parser) void {
        const operator_type: TokenType = self.previous.token_type;
        const parse_rule: *const ParseRule = self.parse_rules.getPtrConst(operator_type);

        // Parse with the next level of precedence or higher
        self.parse_precedence(@enumFromInt(@intFromEnum(parse_rule.precedence) + 1));

        switch (operator_type) {
            TokenType.BangEqual => self.emit_bytes(@intFromEnum(OpCode.Equal), @intFromEnum(OpCode.Not)),
            TokenType.EqualEqual => self.emit_byte(@intFromEnum(OpCode.Equal)),
            TokenType.Greater => self.emit_byte(@intFromEnum(OpCode.Greater)),
            TokenType.GreaterEqual => self.emit_bytes(@intFromEnum(OpCode.Less), @intFromEnum(OpCode.Not)),
            TokenType.Less => self.emit_byte(@intFromEnum(OpCode.Less)),
            TokenType.LessEqual => self.emit_bytes(@intFromEnum(OpCode.Greater), @intFromEnum(OpCode.Not)),
            TokenType.Plus => self.emit_byte(@intFromEnum(OpCode.Add)),
            TokenType.Minus => self.emit_byte(@intFromEnum(OpCode.Substract)),
            TokenType.Star => self.emit_byte(@intFromEnum(OpCode.Multiply)),
            TokenType.Slash => self.emit_byte(@intFromEnum(OpCode.Divide)),
            else => return,
        }
    }

    fn literal(self: *Parser) void {
        switch (self.previous.token_type) {
            TokenType.False => self.emit_byte(@intFromEnum(OpCode.False)),
            TokenType.Nil => self.emit_byte(@intFromEnum(OpCode.Nil)),
            TokenType.True => self.emit_byte(@intFromEnum(OpCode.True)),
            else => return,
        }
    }

    /// Compile expressions that have higher or equal precedence than `precedence`.
    /// If we have: `-a.b + c` then `self.parse_precedence(Precedence.Assignment)`
    /// will parse the entire expression because `+` and `-` has higher precedence than
    /// `=`. If instead we call `self.parse_precedence(Precedence.Unary)`, this will
    /// compile `-a.b` since `+` has lower precedence than unary `-`.
    fn parse_precedence(self: *Parser, precedence: Precedence) void {
        self.advance();
        const parse_rule: *const ParseRule = self.parse_rules.getPtrConst(self.previous.token_type);
        const prefix_rule: *const ParseFn = parse_rule.prefix orelse {
            // `prefix == null` => `self.previous` is not a token that expect
            // an expression next. This is a syntax error.
            self.err("Expect expression.");
            return;
        };

        // Compile the prefix of the expression
        prefix_rule(self);

        // Compile the inf
        while (@intFromEnum(precedence) <= @intFromEnum(self.parse_rules.getPtrConst(self.current.token_type).precedence)) {
            self.advance();
            const infix_rule = self.parse_rules.getPtrConst(self.previous.token_type).infix orelse {
                self.err("Expect expression.");
                return;
            };
            infix_rule(self);
        }
    }

    fn emit_byte(self: *Parser, byte: u8) void {
        self.current_chunk().write_code(byte, self.previous.line) catch {
            self.err("Unable to write chunk.");
            return;
        };
    }

    fn emit_bytes(self: *Parser, byte1: u8, byte2: u8) void {
        self.emit_byte(byte1);
        self.emit_byte(byte2);
    }

    fn emit_return(self: *Parser) void {
        self.emit_byte(@intFromEnum(OpCode.Return));
    }

    fn emit_constant(self: *Parser, value: Value) void {
        self.emit_bytes(@intFromEnum(OpCode.Constant), self.make_constant(value));
    }

    fn make_constant(self: *Parser, value: Value) u8 {
        const idx: usize = self.current_chunk().add_constant(value) catch {
            self.err("Too many constants in one chunk.");
            return 0;
        };

        return @intCast(idx);
    }

    fn current_chunk(self: *Parser) *Chunk {
        return self.compiling_chunk;
    }

    fn err_at_current(self: *Parser, message: []const u8) void {
        self.err_at(&self.current, message);
    }

    fn err(self: *Parser, message: []const u8) void {
        self.err_at(&self.previous, message);
    }

    fn err_at(self: *Parser, token: *Token, message: []const u8) void {
        if (self.panic_mode) return;

        self.panic_mode = true;
        std.debug.print("[Line {}] Error", .{token.line});

        switch (token.token_type) {
            TokenType.EOF => std.debug.print(" at end", .{}),
            TokenType.Error => {}, // do nothing
            else => std.debug.print(" at '{s}'", .{token.start[0..token.length]}),
        }

        std.debug.print(": {s}\n", .{message});
        self.had_error = true;
    }
};

test "compile_unary" {
    for ([_][]const u8{ "-32", "-223.32", "-0", "-0.00" }) |source| {
        const allocator = std.testing.allocator;
        var chunk = Chunk.init(allocator);
        defer chunk.deinit();

        var parser = Parser.init(source, &chunk);
        try parser.compile();

        // OpCode.Constant (2 bytes), OpCode.Negate (1 byte), OpCode.Return (1 byte)
        try testing.expectEqual(4, parser.compiling_chunk.code.items.len);
        try testing.expectEqual(1, parser.compiling_chunk.constants.items.len);

        const expected = try std.fmt.parseFloat(f64, source);
        try testing.expectEqual(-expected, parser.compiling_chunk.constants.items[0].Number);
    }
}

test "compile_binary" {
    for ([_][]const u8{ "32 + 2.322", "1 - 2", "0.0 * 23", "22 / 10" }) |source| {
        const allocator = std.testing.allocator;
        var chunk = Chunk.init(allocator);
        defer chunk.deinit();

        var parser = Parser.init(source, &chunk);
        try parser.compile();

        // OpCode.Constant (4 bytes), OpCode.{Operator} (1 byte), OpCode.Return (1 byte)
        try testing.expectEqual(6, parser.compiling_chunk.code.items.len);
        try testing.expectEqual(2, parser.compiling_chunk.constants.items.len);
    }
}

test "compile_empty" {
    const allocator = std.testing.allocator;
    var chunk = Chunk.init(allocator);
    defer chunk.deinit();

    var parser = Parser.init("", &chunk);
    try testing.expectError(InterpretError.CompileError, parser.compile());
}

test "compile_syntax_error" {
    for ([_][]const u8{ "-return", "for + while", "1 * if", "else / 5", "\"aloha" }) |source| {
        const allocator = std.testing.allocator;
        var chunk = Chunk.init(allocator);
        defer chunk.deinit();

        var parser = Parser.init(source, &chunk);
        try testing.expectError(InterpretError.CompileError, parser.compile());
    }
}
