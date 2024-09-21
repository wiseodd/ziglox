const std = @import("std");
const testing = std.testing;
const VirtualMachine = @import("vm.zig").VirtualMachine;
const InterpretError = @import("vm.zig").InterpretError;
const Scanner = @import("scanner.zig").Scanner;
const Token = @import("token.zig").Token;
const TokenType = @import("token.zig").TokenType;
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const Value = @import("value.zig").Value;
const Obj = @import("object.zig").Obj;
const ObjType = @import("object.zig").ObjType;
const String = @import("object.zig").String;
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

const U8_COUNT: usize = std.math.maxInt(u8) + 1;

// Local variable
const Local = struct {
    name: Token,
    // Null depth means the local var is uninitialized.
    maybe_depth: ?usize,
};

// Storage for local variables
const Compiler = struct {
    locals: [U8_COUNT]Local,
    local_count: usize,
    scope_depth: usize,

    pub fn init() Compiler {
        return Compiler{
            .locals = undefined,
            .local_count = 0,
            .scope_depth = 0,
        };
    }
};

fn identifier_equals(a: *Token, b: *Token) bool {
    if (a.length != b.length) return false;
    return std.mem.eql(u8, a.start[0..a.length], b.start[0..b.length]);
}

pub const Parser = struct {
    // Type alias for parser functions (`unary`, `binary`, etc.)
    const ParseFn = fn (*Parser, bool) void;

    // Rule for parsing
    const ParseRule = struct {
        prefix: ?*const ParseFn = null,
        infix: ?*const ParseFn = null,
        precedence: Precedence = .None,
    };

    // Type alias
    const ParseRules = std.EnumArray(TokenType, ParseRule);

    allocator: std.mem.Allocator,
    source: []const u8,
    scanner: Scanner,
    compiling_chunk: *Chunk,
    strings: *std.StringHashMap(Value),
    compiler: Compiler,
    current_compiler: *Compiler = undefined,
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
        .Identifier = ParseRule{ .prefix = variable, .infix = null, .precedence = Precedence.None },
        .String = ParseRule{ .prefix = string, .infix = null, .precedence = Precedence.None },
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

    pub fn init(
        allocator: std.mem.Allocator,
        source: []const u8,
        chunk: *Chunk,
        strings: *std.StringHashMap(Value),
    ) Parser {
        var parser = Parser{
            .allocator = allocator,
            .source = source,
            .scanner = Scanner.init(source),
            .compiler = Compiler.init(),
            .compiling_chunk = chunk,
            .strings = strings,
        };
        parser.current_compiler = &parser.compiler;
        return parser;
    }

    pub fn compile(self: *Parser) InterpretError!void {
        self.advance();

        while (!self.match(TokenType.EOF)) {
            self.declaration();
        }

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

    fn match(self: *Parser, token_type: TokenType) bool {
        // If the current token has type `token_type`, advance the parser
        // and return true.
        if (!self.check(token_type)) {
            return false;
        }

        self.advance();
        return true;
    }

    fn check(self: *Parser, token_type: TokenType) bool {
        return self.current.token_type == token_type;
    }

    fn end_compiler(self: *Parser) void {
        self.emit_return();

        if (FLAGS.DEBUG_PRINT_CODE) {
            if (!self.had_error) {
                debug.disasemble_chunk(self.current_chunk(), "code");
            }
        }
    }

    fn begin_scope(self: *Parser) void {
        self.current_compiler.scope_depth += 1;
    }

    fn end_scope(self: *Parser) void {
        self.current_compiler.scope_depth -= 1;

        // Clean up after the local scope.
        var curr: *Compiler = self.current_compiler;
        while (curr.local_count > 0 and curr.locals[curr.local_count - 1].maybe_depth.? > curr.scope_depth) {
            // Emit instruction to pop all constants in the stack corresponding to
            // the ending scope.
            self.emit_byte(@intFromEnum(OpCode.Pop));

            // Reduce the number of local variables stored in the compiler.
            curr.local_count -= 1;
        }
    }

    fn expression(self: *Parser) void {
        // Compile all expressions that have higher or equal level of precedence
        // than assignment `=` (the lowest precedence level).
        self.parse_precedence(Precedence.Assignment);
    }

    fn block(self: *Parser) void {
        while (!self.check(TokenType.RightBrace) and !self.check(TokenType.EOF)) {
            self.declaration();
        }

        self.consume(TokenType.RightBrace, "Expect '}' after block.");
    }

    fn expression_statement(self: *Parser) void {
        // E.g.: `var x = 1 + 1;`
        self.expression();
        self.consume(TokenType.SemiColon, "Expect ';' after expression.");
        self.emit_byte(@intFromEnum(OpCode.Pop));
    }

    fn var_declaration(self: *Parser) void {
        const global: u8 = self.parse_variable("Expect variable name.");

        if (self.match(TokenType.Equal)) {
            self.expression();
        } else {
            // If no value is explicitly assigned, assign Nil.
            self.emit_byte(@intFromEnum(OpCode.Nil));
        }

        self.consume(TokenType.SemiColon, "Expect ';' after variable declaration.");
        self.define_variable(global);
    }

    fn declaration(self: *Parser) void {
        if (self.match(TokenType.Var)) {
            self.var_declaration();
        } else {
            self.statement();
        }

        if (self.panic_mode) {
            self.synchronize();
        }
    }

    fn statement(self: *Parser) void {
        if (self.match(TokenType.Print)) {
            self.print_statement();
        } else if (self.match(TokenType.LeftBrace)) {
            self.begin_scope();
            self.block();
            self.end_scope();
        } else {
            self.expression_statement();
        }
    }

    fn print_statement(self: *Parser) void {
        self.expression();
        self.consume(TokenType.SemiColon, "Expect ';' after value.");
        self.emit_byte(@intFromEnum(OpCode.Print));
    }

    fn synchronize(self: *Parser) void {
        self.panic_mode = false;

        // Move the current parser's "cursor" forward to a token that resembles
        // a statement boundary. E.g., a semicolon (end of a statement) or the
        // beginning of a new statement (`if`, `var`, etc.).
        while (self.current.token_type != TokenType.EOF) {
            if (self.previous.token_type == TokenType.SemiColon) {
                return;
            }

            switch (self.current.token_type) {
                TokenType.Class, TokenType.Fun, TokenType.Var, TokenType.For, TokenType.If, TokenType.While, TokenType.Print, TokenType.Return => return,
                else => continue,
            }

            self.advance();
        }
    }

    fn grouping(self: *Parser, can_assign: bool) void {
        // Ignore
        _ = can_assign;

        // The left paren has been consumed, so we can directly
        // evaluate the expression inside the grouping recursively
        self.expression();
        self.consume(TokenType.RightParen, "Expect ')' after expression.");
    }

    fn number(self: *Parser, can_assign: bool) void {
        // Ignore
        _ = can_assign;

        const lexeme: []const u8 = self.previous.start[0..self.previous.length];
        const val: f64 = std.fmt.parseFloat(f64, lexeme) catch {
            self.err("Invalid number string.");
            return;
        };
        self.emit_constant(Value.number(val));
    }

    fn string(self: *Parser, can_assign: bool) void {
        // Ignore
        _ = can_assign;

        // A string token is a [_]const u8{'"', ..., '"'} array.
        // We want to ignore the quotes.
        const chars = self.previous.start[1 .. self.previous.length - 1];
        const val = Value.string(self.allocator, chars, self.strings) catch {
            self.err("Error allocating string.");
            return;
        };
        return self.emit_constant(val);
    }

    fn variable(self: *Parser, can_assign: bool) void {
        self.named_variable(self.previous, can_assign);
    }

    fn named_variable(self: *Parser, name: Token, can_assign: bool) void {
        var get_op: OpCode = undefined;
        var set_op: OpCode = undefined;
        var arg: usize = undefined;

        if (self.resolve_local(self.current_compiler, @constCast(&name))) |the_arg| {
            // Local variable found.
            arg = the_arg;
            get_op = OpCode.GetLocal;
            set_op = OpCode.SetLocal;
        } else {
            // Local variable not found. Must be global.
            arg = self.identifier_constant(@constCast(&name));
            get_op = OpCode.GetGlobal;
            set_op = OpCode.SetGlobal;
        }

        // If current token is "=" then it's an assignment statement.
        // In this case, we parse the expression in the r.h.s., and then emit
        // bytecode for "set" instead of "get".
        if (can_assign and self.match(TokenType.Equal)) {
            self.expression();
            self.emit_bytes(@intFromEnum(set_op), @intCast(arg));
        } else {
            self.emit_bytes(@intFromEnum(get_op), @intCast(arg));
        }
    }

    fn unary(self: *Parser, can_assign: bool) void {
        // Ignore
        _ = can_assign;

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

    fn binary(self: *Parser, can_assign: bool) void {
        // Ignore
        _ = can_assign;

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

    fn literal(self: *Parser, can_assign: bool) void {
        // Ignore
        _ = can_assign;

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

        // Check whether the precedence is low enough to allow for assignment.
        // This is to handle e.g. `a * b = c + d`. `b` has too high of a precedent
        // compared to `=`, so `a * b` must be parsed first and it cannot be assigned
        // by `c + d`. If we don't do this, then we can arrive at `a * (b = c + d)`.
        const can_assign = @intFromEnum(precedence) <= @intFromEnum(Precedence.Assignment);

        // Compile the prefix of the expression
        prefix_rule(self, can_assign);

        // Compile the infix
        while (@intFromEnum(precedence) <= @intFromEnum(self.parse_rules.getPtrConst(self.current.token_type).precedence)) {
            self.advance();
            const infix_rule = self.parse_rules.getPtrConst(self.previous.token_type).infix orelse {
                self.err("Expect expression.");
                return;
            };
            infix_rule(self, can_assign);
        }

        // There is no infix parsing rule for `=`. So, if `=` exists in the infix,
        // it won't be consumed. If that so, nothing else will. It's an error.
        // This is to handle the example above: `a * b = c + d`. Notice that `=` is
        // parsed last.
        if (can_assign and self.match(TokenType.Equal)) {
            self.err("Invalid assignment target.");
        }
    }

    fn parse_variable(self: *Parser, error_message: []const u8) u8 {
        self.consume(TokenType.Identifier, error_message);

        self.declare_variable();
        // If we're at a local scope, we don't store the variable in the constant table.
        if (self.current_compiler.scope_depth > 0) return 0;

        return self.identifier_constant(@constCast(&self.previous));
    }

    fn mark_initialized(self: *Parser) void {
        // Make variables in the scopes above available for the current scope.
        const curr: *Compiler = self.current_compiler;
        curr.locals[curr.local_count - 1].maybe_depth = curr.scope_depth;
    }

    fn identifier_constant(self: *Parser, name: *Token) u8 {
        const obj_str: Value = Value.string(
            self.allocator,
            name.start[0..name.length],
            self.strings,
        ) catch {
            self.err("Unable to initialize variable name.");
            // TODO: Handle allocation error.
            return 0;
        };
        return self.make_constant(obj_str);
    }

    fn declare_variable(self: *Parser) void {
        // This function declares *local* variables.
        if (self.current_compiler.scope_depth == 0) {
            return;
        }

        const name: *Token = &self.previous;

        // Check for duplicate. Current scope is always at the end of the array.
        if (self.current_compiler.local_count > 0) {
            var i: usize = self.current_compiler.local_count - 1;
            while (i >= 0) : (i -= 1) {
                const local: *Local = &self.current_compiler.locals[i];

                if (local.maybe_depth.? != -1 and local.maybe_depth.? < self.current_compiler.scope_depth) {
                    break;
                }

                if (identifier_equals(name, &local.name)) {
                    self.err("Already a variable with this name in this scope");
                }
            }
        }

        self.add_local(name.*);
    }

    fn add_local(self: *Parser, name: Token) void {
        if (self.current_compiler.local_count == U8_COUNT) {
            self.err("Too many local variables in function.");
            return;
        }

        // Store local variable in the current compiler's storage.
        var local: *Local = &self.current_compiler.locals[self.current_compiler.local_count];
        local.name = name;
        local.maybe_depth = null;
        self.current_compiler.local_count += 1;
    }

    fn define_variable(self: *Parser, global: u8) void {
        if (self.current_compiler.scope_depth > 0) {
            // Mark variables in the outer scope as initialized.
            self.mark_initialized();
            return;
        }

        // Global points to the index of the constant table.
        // The variable name (string) is stored there.
        self.emit_bytes(@intFromEnum(OpCode.DefineGlobal), global);
    }

    fn resolve_local(self: *Parser, compiler: *Compiler, name: *Token) ?usize {
        if (compiler.local_count == 0) {
            return null;
        }

        var i: usize = compiler.local_count - 1;
        while (i >= 0) : (i -= 1) {
            const local: *Local = &compiler.locals[i];

            if (identifier_equals(name, &local.name)) {
                if (local.maybe_depth) |_| {
                    return i;
                } else {
                    // Handle the case where `var a = a;`
                    self.err("Can't read local variable in its own initializer");
                }
            }
        }

        // Not found
        return null;
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
