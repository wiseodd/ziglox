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
const Function = @import("object.zig").Function;
const FunctionType = @import("object.zig").FunctionType;
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
    is_captured: bool,
};

// Upvalue variables for closures
const Upvalue = struct {
    index: u8,
    is_local: bool,
};

// Storage for local variables
pub const Compiler = struct {
    enclosing: ?*Compiler,
    function: *Function,
    fun_type: FunctionType,
    locals: [U8_COUNT]Local,
    local_count: usize,
    upvalues: [U8_COUNT]Upvalue,
    scope_depth: usize,

    /// The reason we do `ptr = allocator.create(T); ptr.* = ...` is so that
    /// the newly initialized Compiler object lives in the heap. Otherwise, we will
    /// have an undefined behavior (use-after-free).
    pub fn init(
        vm: *VirtualMachine,
        fun_type: FunctionType,
        enclosing: ?*Compiler,
    ) !*Compiler {
        const ptr = try vm.allocator.create(Compiler);

        ptr.* = Compiler{
            .enclosing = enclosing,
            .function = try Function.init(vm),
            .fun_type = fun_type,
            .locals = undefined,
            .local_count = 0,
            .upvalues = undefined,
            .scope_depth = 0,
        };

        var local = ptr.locals[ptr.local_count];
        ptr.local_count += 1;
        local.maybe_depth = 0;
        local.is_captured = false;
        local.name.start = "";
        local.name.length = 0;

        return ptr;
    }

    pub fn deinit(self: *Compiler, vm: *VirtualMachine) void {
        vm.allocator.destroy(self);
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

    vm: *VirtualMachine,
    source: []const u8,
    scanner: Scanner,
    current_compiler: *Compiler,
    local: *Local = undefined,
    current: Token = undefined,
    previous: Token = undefined,
    had_error: bool = false,
    panic_mode: bool = false,

    // We build a static parse rules table here and access it through pointers.
    // It's more efficient than having a function that return a new `ParseRule` each time.
    parse_rules: ParseRules = ParseRules.init(.{
        .LeftParen = ParseRule{ .prefix = grouping, .infix = call, .precedence = Precedence.Call },
        .RightParen = ParseRule{},
        .LeftBrace = ParseRule{},
        .RightBrace = ParseRule{},
        .Comma = ParseRule{},
        .Dot = ParseRule{ .prefix = null, .infix = dot, .precedence = Precedence.Call },
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
        .And = ParseRule{ .prefix = null, .infix = and_, .precedence = Precedence.And },
        .Class = ParseRule{},
        .Else = ParseRule{},
        .False = ParseRule{ .prefix = literal, .infix = null, .precedence = Precedence.None },
        .For = ParseRule{},
        .Fun = ParseRule{},
        .If = ParseRule{},
        .Nil = ParseRule{ .prefix = literal, .infix = null, .precedence = Precedence.None },
        .Or = ParseRule{ .prefix = null, .infix = or_, .precedence = Precedence.Or },
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
        vm: *VirtualMachine,
        source: []const u8,
    ) !Parser {
        return Parser{
            .vm = vm,
            .source = source,
            .scanner = Scanner.init(source),
            .current_compiler = try Compiler.init(vm, .Script, null),
        };
    }

    pub fn compile(self: *Parser) InterpretError!*Function {
        self.advance();

        while (!self.match(TokenType.EOF)) {
            self.declaration();
        }

        const function = self.end_compiler();

        if (self.had_error) {
            return InterpretError.CompileError;
        } else {
            return function;
        }
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

    fn end_compiler(self: *Parser) *Function {
        self.emit_return();
        const function = self.current_compiler.function;

        if (FLAGS.DEBUG_PRINT_CODE) {
            if (!self.had_error) {
                debug.disasemble_chunk(self.current_chunk(), if (function.name) |name| name.chars else "<script>");
            }
        }

        // Set the current compiler to the previous one in the stack, if any
        if (self.current_compiler.enclosing) |enclosing| {
            self.current_compiler = enclosing;
        }

        return function;
    }

    fn begin_scope(self: *Parser) void {
        self.current_compiler.scope_depth += 1;
    }

    fn end_scope(self: *Parser) void {
        self.current_compiler.scope_depth -= 1;

        // Clean up after the local scope.
        var curr: *Compiler = self.current_compiler;
        while (curr.local_count > 0 and curr.locals[curr.local_count - 1].maybe_depth != null and curr.locals[curr.local_count - 1].maybe_depth.? > curr.scope_depth) {
            // Emit instruction to pop all constants in the stack corresponding to
            // the ending scope.
            if (curr.locals[curr.local_count - 1].is_captured) {
                self.emit_byte(@intFromEnum(OpCode.CloseUpvalue));
            } else {
                self.emit_byte(@intFromEnum(OpCode.Pop));
            }

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

    fn fun(self: *Parser, fun_type: FunctionType) void {
        const compiler = Compiler.init(self.vm, fun_type, self.current_compiler) catch {
            self.err("Error allocating compiler.");
            return;
        };
        defer compiler.deinit(self.vm);

        self.current_compiler = compiler;

        if (fun_type != .Script) {
            self.current_compiler.function.name = String.init(
                self.previous.start[0..self.previous.length],
                self.vm,
            ) catch {
                self.err("Error allocating string.");
                return;
            };
        }

        self.begin_scope();

        self.consume(TokenType.LeftParen, "Expect '(' after function name.");

        if (!self.check(TokenType.RightParen)) {
            // Parse each parameter
            while (true) {
                self.current_compiler.function.arity += 1;

                if (self.current_compiler.function.arity > 255) {
                    self.err_at_current("Can't have more than 255 parameters.");
                }

                const constant: u8 = self.parse_variable("Expect parameter name.");
                self.define_variable(constant);

                if (!self.match(TokenType.Comma)) {
                    break;
                }
            }
        }

        self.consume(TokenType.RightParen, "Expect ')' after parameters.");
        self.consume(TokenType.LeftBrace, "Expect '{' before function body.");

        self.block();

        const function = self.end_compiler();
        const val = Value.obj(function.as_obj());
        self.emit_bytes(@intFromEnum(OpCode.Closure), self.make_constant(val));

        for (compiler.upvalues[0..function.upvalue_count]) |upvalue| {
            self.emit_byte(if (upvalue.is_local) 1 else 0);
            self.emit_byte(upvalue.index);
        }
    }

    fn method(self: *Parser) void {
        // Method name
        self.consume(TokenType.Identifier, "Expect method name.");
        const constant: u8 = self.identifier_constant(&self.previous);

        // Method body
        self.fun(FunctionType.Function);

        self.emit_bytes(@intFromEnum(OpCode.Method), constant);
    }

    fn class_declaration(self: *Parser) void {
        self.consume(TokenType.Identifier, "Expect class name.");
        const class_name: Token = self.previous;
        const name_constant: u8 = self.identifier_constant(&self.previous);
        self.declare_variable();

        self.emit_bytes(@intFromEnum(OpCode.Class), name_constant);
        self.define_variable(name_constant);
        self.named_variable(class_name, false);

        self.consume(TokenType.LeftBrace, "Expect '{' before class body.");

        // Parse the inside of the class
        while (!self.check(TokenType.RightBrace) and !self.check(TokenType.EOF)) {
            self.method();
        }

        self.consume(TokenType.RightBrace, "Expect '}' after class body.");

        self.emit_byte(@intFromEnum(OpCode.Pop));
    }

    fn fun_declaration(self: *Parser) void {
        const global: u8 = self.parse_variable("Expect function name.");
        self.mark_initialized();
        self.fun(FunctionType.Function);
        self.define_variable(global);
    }

    fn expression_statement(self: *Parser) void {
        // E.g.: `var x = 1 + 1;`
        self.expression();
        self.consume(TokenType.SemiColon, "Expect ';' after expression.");
        self.emit_byte(@intFromEnum(OpCode.Pop));
    }

    /// Syntax: `for(var i = 0; i <= 10; i += 1)` or `for(;;)`
    /// The first clause is the "initializer clause" then the "condition" and
    /// "increment" clauses respectively.
    fn for_statement(self: *Parser) void {
        self.begin_scope();

        self.consume(TokenType.LeftParen, "Expect '(' after 'for'.");

        // Initializer clause
        if (self.match(TokenType.SemiColon)) {
            // No initializer
        } else if (self.match(TokenType.Var)) {
            self.var_declaration();
        } else {
            self.expression_statement();
        }

        var loop_start: usize = self.current_chunk().code.items.len;
        var exit_jump: ?usize = null;

        // Condition clause
        if (!self.match(TokenType.SemiColon)) {
            self.expression();
            self.consume(TokenType.SemiColon, "Expect ';' after loop condition.");

            // Mark out of the loop once the condition is false
            exit_jump = self.emit_jump(OpCode.JumpIfFalse);

            // The loop condition is stored in the stack
            self.emit_byte(@intFromEnum(OpCode.Pop));
        }

        // Increment clause
        if (!self.match(TokenType.RightParen)) {
            const body_jump: usize = self.emit_jump(OpCode.Jump);
            const increment_start: usize = self.current_chunk().code.items.len;

            self.expression();
            self.emit_byte(@intFromEnum(OpCode.Pop));
            self.consume(TokenType.RightParen, "Expect ')' after 'for' clauses.");

            self.emit_loop(loop_start);
            loop_start = increment_start;
            self.patch_jump(body_jump);
        }

        self.statement();
        self.emit_loop(loop_start);

        // Only done if there is a condition clause.
        // Otherwise `exit_jump` is always `null`.
        if (exit_jump) |offset| {
            self.patch_jump(offset);
            self.emit_byte(@intFromEnum(OpCode.Pop));
        }

        self.end_scope();
    }

    fn if_statement(self: *Parser) void {
        // Parse the `if` condition.
        self.consume(TokenType.LeftParen, "Expect '(' after 'if'.");
        self.expression();
        self.consume(TokenType.RightParen, "Expect ')' after condition.");

        // Create a placeholder for jump instruction to skip the `if` block.
        const then_jump: usize = self.emit_jump(OpCode.JumpIfFalse);

        // Pop the value corresponding to the `if` condition *if* the `if` block is
        // executed (`JumpIfFalse` is not executed). Otherwise this will be jumped over.
        self.emit_byte(@intFromEnum(OpCode.Pop));

        // Parse the `if` block.
        self.statement();

        // Create a placeholder for jump instruction to skip the `else` block.
        const else_jump: usize = self.emit_jump(OpCode.Jump);

        // At this point, we know how much jump to make to skip the `if` block and
        // the else-jump instructions.
        self.patch_jump(then_jump);

        // Pop the value corresponding to the `if` condition *if* the `else` block is
        // executed (`JumpIfFalse` is executed). Otherwise this will be jumped over.
        self.emit_byte(@intFromEnum(OpCode.Pop));

        // Parse the `else` block.
        if (self.match(TokenType.Else)) {
            self.statement();
        }

        // At this point, we know how much jump to make to skip the `else` block.
        self.patch_jump(else_jump);
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
        if (self.match(TokenType.Class)) {
            self.class_declaration();
        } else if (self.match(TokenType.Fun)) {
            self.fun_declaration();
        } else if (self.match(TokenType.Var)) {
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
        } else if (self.match(TokenType.For)) {
            self.for_statement();
        } else if (self.match(TokenType.If)) {
            self.if_statement();
        } else if (self.match(TokenType.Return)) {
            self.return_statement();
        } else if (self.match(TokenType.While)) {
            self.while_statement();
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

    fn return_statement(self: *Parser) void {
        if (self.current_compiler.fun_type == .Script) {
            self.err("Can't return from top-level code.");
        }

        if (self.match(TokenType.SemiColon)) {
            self.emit_return();
        } else {
            self.expression();
            self.consume(TokenType.SemiColon, "Expect ';' after return value.");
            self.emit_byte(@intFromEnum(OpCode.Return));
        }
    }

    fn while_statement(self: *Parser) void {
        const loop_start: usize = self.current_chunk().code.items.len;

        self.consume(TokenType.LeftParen, "Expect '(' after 'while'.");
        self.expression();
        self.consume(TokenType.RightParen, "Expect ')' after condition.");

        const exit_jump: usize = self.emit_jump(OpCode.JumpIfFalse);
        self.emit_byte(@intFromEnum(OpCode.Pop));

        self.statement();
        self.emit_loop(loop_start);

        self.patch_jump(exit_jump);
        self.emit_byte(@intFromEnum(OpCode.Pop));
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

    fn or_(self: *Parser, can_assign: bool) void {
        _ = can_assign;

        const else_jump: usize = self.emit_jump(OpCode.JumpIfFalse);
        const end_jump: usize = self.emit_jump(OpCode.Jump);

        self.patch_jump(else_jump);
        self.emit_byte(@intFromEnum(OpCode.Pop));

        self.parse_precedence(Precedence.Or);
        self.patch_jump(end_jump);
    }

    fn string(self: *Parser, can_assign: bool) void {
        // Ignore
        _ = can_assign;

        // A string token is a [_]const u8{'"', ..., '"'} array.
        // We want to ignore the quotes.
        const chars = self.previous.start[1 .. self.previous.length - 1];
        const str = String.init(chars, self.vm) catch {
            self.err("Error allocating string.");
            return;
        };
        const val = Value.obj(str.as_obj());
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
        } else if (self.resolve_upvalue(self.current_compiler, @constCast(&name))) |the_arg| {
            arg = the_arg;
            get_op = OpCode.GetUpvalue;
            set_op = OpCode.SetUpvalue;
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

    fn call(self: *Parser, can_assign: bool) void {
        // Ignore
        _ = can_assign;

        const arg_count: u8 = self.argument_list();
        self.emit_bytes(@intFromEnum(OpCode.Call), arg_count);
    }

    fn dot(self: *Parser, can_assign: bool) void {
        self.consume(TokenType.Identifier, "Expect property name after '.'.");
        const name: u8 = self.identifier_constant(&self.previous);

        if (can_assign and self.match(TokenType.Equal)) {
            self.expression();
            self.emit_bytes(@intFromEnum(OpCode.SetProperty), name);
        } else {
            self.emit_bytes(@intFromEnum(OpCode.GetProperty), name);
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
        // We only initialize in the local scope. Scope depth 0 => global scope.
        if (self.current_compiler.scope_depth == 0) return;

        // Make variables in the scopes above available for the current scope.
        const curr = self.current_compiler;
        curr.locals[curr.local_count - 1].maybe_depth = curr.scope_depth;
    }

    fn identifier_constant(self: *Parser, name: *Token) u8 {
        const obj_str = String.init(name.start[0..name.length], self.vm) catch {
            self.err("Unable to initialize variable name.");
            return 0;
        };

        return self.make_constant(Value.obj(obj_str.as_obj()));
    }

    fn declare_variable(self: *Parser) void {
        // This function declares *local* variables.
        if (self.current_compiler.scope_depth == 0) {
            return;
        }

        const name: *Token = &self.previous;

        // Check for duplicate. Current scope is always at the end of the array.
        if (self.current_compiler.local_count > 0) {
            var i: usize = self.current_compiler.local_count;

            while (i > 0) {
                i -= 1;

                const local: *Local = &self.current_compiler.locals[i];

                if (local.maybe_depth) |depth| {
                    if (depth < self.current_compiler.scope_depth) {
                        break;
                    }
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
        self.current_compiler.local_count += 1;
        local.name = name;
        local.maybe_depth = null;
        local.is_captured = false;
    }

    fn define_variable(self: *Parser, global: u8) void {
        if (self.current_compiler.scope_depth > 0) {
            self.mark_initialized();
            return;
        }

        // Global points to the index of the constant table.
        // The variable name (string) is stored there.
        self.emit_bytes(@intFromEnum(OpCode.DefineGlobal), global);
    }

    fn argument_list(self: *Parser) u8 {
        var arg_count: u8 = 0;

        if (!self.check(TokenType.RightParen)) {
            while (true) {
                self.expression();

                if (arg_count == 255) {
                    self.err("Can't have more than 255 arguments.");
                }

                arg_count += 1;

                if (!self.match(TokenType.Comma)) {
                    break;
                }
            }
        }

        _ = self.consume(TokenType.RightParen, "Expect ')' after arguments.");

        return arg_count;
    }

    fn and_(self: *Parser, can_assign: bool) void {
        _ = can_assign;

        const end_jump: usize = self.emit_jump(OpCode.JumpIfFalse);

        self.emit_byte(@intFromEnum(OpCode.Pop));
        self.parse_precedence(Precedence.And);

        self.patch_jump(end_jump);
    }

    fn resolve_local(self: *Parser, compiler: *Compiler, name: *Token) ?usize {
        if (compiler.local_count == 0) {
            return null;
        }

        var i: usize = compiler.local_count;

        while (i > 0) {
            i -= 1;

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

    fn add_upvalue(self: *Parser, compiler: *Compiler, index: u8, is_local: bool) usize {
        const upvalue_count = compiler.function.upvalue_count;

        for (compiler.upvalues, 0..) |upvalue, i| {
            if (upvalue.index == index and upvalue.is_local == is_local) {
                return i;
            }
        }

        if (upvalue_count == U8_COUNT) {
            self.err("Too many closure variables in function.");
            return 0;
        }

        compiler.upvalues[upvalue_count].is_local = is_local;
        compiler.upvalues[upvalue_count].index = index;
        compiler.function.upvalue_count += 1;

        return upvalue_count;
    }

    fn resolve_upvalue(self: *Parser, compiler: *Compiler, name: *Token) ?usize {
        if (compiler.enclosing) |enclosing| {
            // Check if the variable is local
            if (self.resolve_local(enclosing, name)) |local| {
                enclosing.locals[local].is_captured = true;
                return self.add_upvalue(compiler, @intCast(local), true);
            }

            // Recursively check the variable in the outer scope
            if (self.resolve_upvalue(enclosing, name)) |upvalue| {
                return self.add_upvalue(compiler, @intCast(upvalue), false);
            }
        }

        // If not found, the variable is global
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

    fn emit_loop(self: *Parser, loop_start: usize) void {
        self.emit_byte(@intFromEnum(OpCode.Loop));

        // Jump backward!
        const offset: usize = self.current_chunk().code.items.len - loop_start + 2;

        if (offset > std.math.maxInt(u16)) {
            self.err("Loop body too large.");
        }

        self.emit_byte(@intCast((offset >> 8) & 0xff));
        self.emit_byte(@intCast(offset & 0xff));
    }

    fn emit_jump(self: *Parser, instruction: OpCode) usize {
        self.emit_byte(@intFromEnum(instruction));

        // 2 bytes for the jump offset. 0xff is a placeholder value since we don't
        // know the offset yet --- we haven't parsed e.g. the `if` body at this point.
        self.emit_byte(0xff);
        self.emit_byte(0xff);

        // Return the offset of *the instruction*, not the operand.
        return self.current_chunk().code.items.len - 2;
    }

    fn emit_return(self: *Parser) void {
        self.emit_byte(@intFromEnum(OpCode.Nil));
        self.emit_byte(@intFromEnum(OpCode.Return));
    }

    fn emit_constant(self: *Parser, value: Value) void {
        self.emit_bytes(@intFromEnum(OpCode.Constant), self.make_constant(value));
    }

    fn make_constant(self: *Parser, value: Value) u8 {
        // Together with the pop below, making the value visible to the GC ---
        // to make sure it doesn't get freed by the GC.
        self.vm.push(value) catch {
            self.err("Error push constant to the stack.");
            return 0;
        };

        const idx: usize = self.current_chunk().add_constant(value) catch {
            self.err("Too many constants in one chunk.");
            return 0;
        };

        _ = self.vm.pop() catch {
            self.err("Error popping constant from the stack.");
            return 0;
        };

        return @intCast(idx);
    }

    fn patch_jump(self: *Parser, offset: usize) void {
        // Calculate how much jump do we want to do.
        // `code.items` now contains all instructions in the e.g. `if` block since
        // this function is called after we're done parsing them. At this point, we know
        // exactly how much jump we want to make.
        // Note that, -2 is for the 2-byte jump offset operand. See `emit_jump`.
        const jump: usize = self.current_chunk().code.items.len - offset - 2;

        // Can only do 2-byte jumps.
        if (jump > std.math.maxInt(u16)) {
            self.err("Too much code to jump over.");
        }

        // Replace the placeholder value 0xff in the jump offset operads set by
        // `emit_jump`.
        // -----------------------------------------------------------------------------
        // `jump >> 8` means we discard the first 8 least significant bits, eqivalently,
        // `jump / 2^8`. Then, `num & 0xff` keeps only the lowes 8 bits.
        // So, the first one keeps the 8 most significant bits of u16, while the second
        // keeps the 8 least significant bits of u16.
        self.current_chunk().code.items[offset] = @intCast((jump >> 8) & 0xff);
        self.current_chunk().code.items[offset + 1] = @intCast(jump & 0xff);
    }

    fn current_chunk(self: *Parser) *Chunk {
        return &self.current_compiler.function.chunk;
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
