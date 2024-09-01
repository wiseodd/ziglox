const std = @import("std");
const InterpretError = @import("vm.zig").InterpretError;
const Scanner = @import("scanner.zig").Scanner;
const Token = @import("token.zig").Token;
const TokenType = @import("token.zig").TokenType;
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const Value = @import("value.zig").Value;

pub const Parser = struct {
    source: []const u8,
    scanner: Scanner,
    compiling_chunk: *Chunk,
    current: Token = undefined,
    previous: Token = undefined,
    had_error: bool = false,
    panic_mode: bool = false,

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

    fn expression(self: *Parser) void {
        _ = self;
        return; // TODO
    }

    fn end_compiler(self: *Parser) void {
        self.emit_return();
    }

    fn number(self: *Parser) void {
        const lexeme: []const u8 = self.previous.start[0..self.previous.length];
        const val: f64 = std.fmt.parseFloat(f64, lexeme) catch {
            self.err("Invalid number string.");
            return;
        };
        self.emit_constant(val);
    }

    fn emit_byte(self: *Parser, byte: u8) void {
        self.write_chunk(self.current_chunk(), byte, self.previous.line);
    }

    fn emit_bytes(self: *Parser, byte1: u8, byte2: u8) void {
        self.emit_byte(byte1);
        self.emit_byte(byte2);
    }

    fn emit_return(self: *Parser) void {
        self.emit_byte(@intFromEnum(OpCode.Return));
    }

    fn emit_constant(self: *Parser, value: Value) void {
        self.emit_bytes(OpCode.Constant, self.make_constant(value));
    }

    fn make_constant(self: *Parser, value: Value) u8 {
        const idx: usize = self.chunk.add_constant(value) catch {
            self.err("Too many constants in one chunk.");
            return 0;
        };

        return @intCast(idx);
    }

    fn current_chunk(self: *Parser) *Chunk {
        return self.compiling_chunk;
    }

    fn write_chunk(self: *Parser, chunk: *Chunk, byte: u8, line: usize) void {
        // TODO
        _ = chunk;
        _ = self;
        _ = byte;
        _ = line;
        return;
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
        std.log.err("[line {}] Error", .{token.line});

        switch (token.token_type) {
            TokenType.EOF => std.log.err(" at end", .{}),
            TokenType.Error => {}, // do nothing
            else => std.log.err(" at '{s}'", .{token.start[0..token.length]}),
        }

        std.log.err(": {s}\n", .{message});
        self.had_error = true;
    }
};
