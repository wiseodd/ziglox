const std = @import("std");
const Token = @import("token.zig").Token;
const TokenType = @import("token.zig").TokenType;

pub const Scanner = struct {
    start: [*]const u8,
    current: [*]const u8,
    end: [*]const u8,
    line: usize,
    length: usize,

    pub fn init(source: []const u8) Scanner {
        return Scanner{
            .start = source.ptr,
            .current = source.ptr,
            .end = @ptrCast(&source[source.len - 1]),
            .line = 1,
            .length = source.len,
        };
    }

    pub fn scan(self: *Scanner) Token {
        self.skip_whitespace();
        self.start = self.current;

        if (self.is_at_end()) {
            return Token.init(self, TokenType.EOF);
        }

        const c: u8 = self.advance();

        if (is_alpha(c)) return self.identifier();
        if (is_digit(c)) return self.number();

        switch (c) {
            '(' => return Token.init(self, TokenType.LeftParen),
            ')' => return Token.init(self, TokenType.RightParen),
            '{' => return Token.init(self, TokenType.LeftBrace),
            '}' => return Token.init(self, TokenType.RightBrace),
            ';' => return Token.init(self, TokenType.SemiColon),
            ',' => return Token.init(self, TokenType.Comma),
            '.' => return Token.init(self, TokenType.Dot),
            '-' => return Token.init(self, TokenType.Minus),
            '+' => return Token.init(self, TokenType.Plus),
            '/' => return Token.init(self, TokenType.Slash),
            '*' => return Token.init(self, TokenType.Star),
            '!' => return Token.init(self, if (self.match('=')) TokenType.BangEqual else TokenType.Bang),
            '=' => return Token.init(self, if (self.match('=')) TokenType.EqualEqual else TokenType.Equal),
            '<' => return Token.init(self, if (self.match('=')) TokenType.LessEqual else TokenType.Less),
            '>' => return Token.init(self, if (self.match('=')) TokenType.GreaterEqual else TokenType.Greater),
            '"' => return self.string(),
            else => unreachable,
        }

        return Token.init_error(self, "Unexpected character.");
    }

    fn is_at_end(self: *Scanner) bool {
        return @intFromPtr(self.current) > @intFromPtr(self.end);
    }

    fn advance(self: *Scanner) u8 {
        const char: u8 = self.current[0];
        self.current += 1;
        return char;
    }

    fn match(self: *Scanner, expected: u8) bool {
        if (self.is_at_end()) return false;
        if (self.current[0] != expected) return false;

        self.current += 1;
        return true;
    }

    fn skip_whitespace(self: *Scanner) void {
        while (true) {
            const c: u8 = self.peek();

            switch (c) {
                ' ', '\r', '\t' => {
                    _ = self.advance();
                },
                '\n' => {
                    self.line += 1;
                    _ = self.advance();
                },
                '/' => {
                    if (self.peek_next() == '/') {
                        // Consume until the end of line
                        while (self.peek() != '\n' and !self.is_at_end()) {
                            _ = self.advance();
                        }
                    } else {
                        // If the next char is not another '/' then the first '/'
                        // is actually not a comment, instead e.g. division.
                        return;
                    }
                },
                else => return,
            }
        }
    }

    fn string(self: *Scanner) Token {
        while (self.peek() != '"' and !self.is_at_end()) {
            // For multi-line strings
            if (self.peek() == '\n') {
                self.line += 1;
            }

            _ = self.advance();
        }

        if (self.is_at_end()) {
            return Token.init_error(self, "Unterminated string.");
        }

        // The closing quote
        _ = self.advance();
        return Token.init(self, TokenType.String);
    }

    /// In the scanning process, numbers are represented by strings
    fn number(self: *Scanner) Token {
        // Gather all the digits
        while (is_digit(self.peek())) {
            _ = self.advance();
        }

        // Look for fractional part
        if (self.peek() == '.' and is_digit(self.peek_next())) {
            // Consume the '.'
            _ = self.advance();

            // Consume the rest of the fractional digits
            while (is_digit(self.peek())) {
                _ = self.advance();
            }
        }

        return Token.init(self, TokenType.Number);
    }

    fn identifier(self: *Scanner) Token {
        const c: u8 = self.peek();

        while (is_alpha(c) or is_digit(c)) {
            _ = self.advance();
        }

        return Token.init(self, identifier_type());
    }

    fn peek(self: *Scanner) u8 {
        return self.current[0];
    }

    fn peek_next(self: *Scanner) u8 {
        if (self.is_at_end()) return 0;
        return self.current[1];
    }

    fn identifier_type() TokenType {
        return TokenType.Identifier;
    }

    fn is_digit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn is_alpha(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
    }
};
