const std = @import("std");
const expectEqual = @import("std").testing.expectEqual;
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
            .end = if (source.len == 0) source.ptr else @ptrCast(&source[source.len - 1]),
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

        return switch (c) {
            '(' => Token.init(self, TokenType.LeftParen),
            ')' => Token.init(self, TokenType.RightParen),
            '{' => Token.init(self, TokenType.LeftBrace),
            '}' => Token.init(self, TokenType.RightBrace),
            ';' => Token.init(self, TokenType.SemiColon),
            ',' => Token.init(self, TokenType.Comma),
            '.' => Token.init(self, TokenType.Dot),
            '-' => Token.init(self, TokenType.Minus),
            '+' => Token.init(self, TokenType.Plus),
            '/' => Token.init(self, TokenType.Slash),
            '*' => Token.init(self, TokenType.Star),
            '!' => Token.init(self, if (self.match('=')) TokenType.BangEqual else TokenType.Bang),
            '=' => Token.init(self, if (self.match('=')) TokenType.EqualEqual else TokenType.Equal),
            '<' => Token.init(self, if (self.match('=')) TokenType.LessEqual else TokenType.Less),
            '>' => Token.init(self, if (self.match('=')) TokenType.GreaterEqual else TokenType.Greater),
            '"' => self.string(),
            else => Token.init_error(self, "Unexpected character"),
        };
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
        while (is_alpha(self.peek()) or is_digit(self.peek())) {
            _ = self.advance();
        }

        return Token.init(self, self.identifier_type());
    }

    fn identifier_type(self: *Scanner) TokenType {
        // Traverse the Trie of Lox's keywords
        switch (self.start[0]) {
            'a' => return self.check_keyword(1, 2, "nd", TokenType.And),
            'c' => return self.check_keyword(1, 4, "lass", TokenType.Class),
            'e' => return self.check_keyword(1, 3, "lse", TokenType.Else),
            'f' => {
                // Branching in the Trie.
                // First, check whether there is a second letter after self.start.
                if (@intFromPtr(self.current) - @intFromPtr(self.start) > 1) {
                    return switch (self.start[1]) {
                        'a' => self.check_keyword(2, 3, "lse", TokenType.False),
                        'o' => self.check_keyword(2, 1, "r", TokenType.For),
                        'u' => self.check_keyword(2, 1, "n", TokenType.Fun),
                        else => TokenType.Identifier,
                    };
                } else {
                    return TokenType.Identifier;
                }
            },
            'i' => return self.check_keyword(1, 1, "f", TokenType.If),
            'n' => return self.check_keyword(1, 2, "il", TokenType.Nil),
            'o' => return self.check_keyword(1, 1, "r", TokenType.Or),
            'p' => return self.check_keyword(1, 4, "rint", TokenType.Print),
            'r' => return self.check_keyword(1, 5, "eturn", TokenType.Return),
            's' => return self.check_keyword(1, 4, "uper", TokenType.Super),
            't' => {
                if (@intFromPtr(self.current) - @intFromPtr(self.start) > 1) {
                    return switch (self.start[1]) {
                        'h' => self.check_keyword(2, 2, "is", TokenType.This),
                        'r' => self.check_keyword(2, 2, "ue", TokenType.True),
                        else => TokenType.Identifier,
                    };
                } else {
                    return TokenType.Identifier;
                }
            },
            'v' => return self.check_keyword(1, 2, "ar", TokenType.Var),
            'w' => return self.check_keyword(1, 4, "hile", TokenType.While),
            else => return TokenType.Identifier,
        }
    }

    fn check_keyword(
        self: *Scanner,
        rest_start: usize,
        rest_length: usize,
        rest_str: []const u8,
        token_type: TokenType,
    ) TokenType {
        // The length of the  lexeme under the scanner must equal the keyword's length
        const lexeme_length: usize = @intFromPtr(self.current) - @intFromPtr(self.start);
        const keyword_length: usize = rest_start + rest_length;
        const cond1: bool = lexeme_length == keyword_length;

        // The rest of the lexeme (starting from self.start[0] + rest_start)
        // must equal the rest's string.
        const cond2: bool = std.mem.eql(
            u8,
            self.start[rest_start .. rest_start + rest_length], // [..)
            rest_str,
        );

        if (cond1 and cond2) {
            return token_type;
        } else {
            return TokenType.Identifier;
        }
    }

    fn is_at_end(self: *Scanner) bool {
        if (self.length == 0) {
            return true;
        } else {
            return @intFromPtr(self.current) > @intFromPtr(self.end);
        }
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

    fn peek(self: *Scanner) u8 {
        return self.current[0];
    }

    fn peek_next(self: *Scanner) u8 {
        if (self.is_at_end()) return 0;
        return self.current[1];
    }

    fn is_digit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn is_alpha(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
    }
};

test "scanner_init" {
    const source = "1 + 1 = 2;\nfor (var i = 0; i < 10; i++) { print i; }";
    const scanner = Scanner.init(source);

    try expectEqual(source.ptr, scanner.start);
    try expectEqual(source.ptr, scanner.start);

    const expected: [*]const u8 = @ptrCast(&source[source.len - 1]);
    try expectEqual(expected, scanner.end);

    try expectEqual(1, scanner.line);
    try expectEqual(source.len, scanner.length);
}

test "scan_whitespaces" {
    var scanner = Scanner.init("\n\t\t  // comment\n var");
    const result: Token = scanner.scan();
    const expected: Token = Token.init(&scanner, TokenType.Var);

    try expectEqual(expected, result);
}

test "scan_eof" {
    var scanner = Scanner.init("");
    const result: Token = scanner.scan();
    const expected: Token = Token.init(&scanner, TokenType.EOF);

    try expectEqual(expected, result);
}

test "scan_identifiers" {
    const identifiers = [_]struct { TokenType, []const u8 }{
        .{ TokenType.And, "and" },
        .{ TokenType.Class, "class" },
        .{ TokenType.Else, "else" },
        .{ TokenType.False, "false" },
        .{ TokenType.For, "for" },
        .{ TokenType.Fun, "fun" },
        .{ TokenType.If, "if" },
        .{ TokenType.Nil, "nil" },
        .{ TokenType.Or, "or" },
        .{ TokenType.Print, "print" },
        .{ TokenType.Return, "return" },
        .{ TokenType.Super, "super" },
        .{ TokenType.This, "this" },
        .{ TokenType.True, "true" },
        .{ TokenType.Var, "var" },
        .{ TokenType.While, "while" },
        .{ TokenType.Identifier, "nothing" },
    };

    for (identifiers) |tuple| {
        var scanner = Scanner.init(tuple[1]);
        const result: Token = scanner.scan();
        const expected: Token = Token.init(&scanner, tuple[0]);

        try expectEqual(expected, result);
        try expectEqual(tuple[1].len, result.length);
    }
}

test "scan_numbers" {
    const sources = [_][]const u8{ "1231231 and for", "213123.43;", "8853.000" };
    const lengths = [_]usize{ 7, 9, 8 };

    for (sources, lengths) |source, len| {
        var scanner = Scanner.init(source);
        const result: Token = scanner.scan();
        const expected: Token = Token.init(&scanner, TokenType.Number);

        try expectEqual(expected, result);
        try expectEqual(len, result.length);
    }
}

test "scan_strings" {
    // String
    var scanner = Scanner.init("\"this is a string\" - qwerty");
    var result: Token = scanner.scan();
    var expected: Token = Token.init(&scanner, TokenType.String);

    try expectEqual(expected, result);
    try expectEqual(18, result.length);

    // Multiline string
    scanner = Scanner.init("\"this is a multiline string\n\tasdsadsad\nasda\"");
    result = scanner.scan();
    expected = Token.init(&scanner, TokenType.String);

    try expectEqual(expected, result);
    try expectEqual(3, result.line);

    // Invalid string
    scanner = Scanner.init("\"this is a string - qwerty");
    result = scanner.scan();

    try expectEqual(TokenType.Error, result.token_type);

    // Invalid multiline string
    scanner = Scanner.init("\"this is a multiline string\n\tasdsadsad\nasda'");
    result = scanner.scan();

    try expectEqual(TokenType.Error, result.token_type);
}

test "scan_tokens_rest" {
    const tokens = [_]struct { TokenType, []const u8 }{
        .{ TokenType.LeftParen, "(" },
        .{ TokenType.RightParen, ")" },
        .{ TokenType.LeftBrace, "{" },
        .{ TokenType.RightBrace, "}" },
        .{ TokenType.SemiColon, ";" },
        .{ TokenType.Comma, "," },
        .{ TokenType.Dot, "." },
        .{ TokenType.Minus, "-" },
        .{ TokenType.Plus, "+" },
        .{ TokenType.Slash, "/" },
        .{ TokenType.Star, "*" },
        .{ TokenType.BangEqual, "!=" },
        .{ TokenType.Bang, "!" },
        .{ TokenType.EqualEqual, "==" },
        .{ TokenType.Equal, "=" },
        .{ TokenType.LessEqual, "<=" },
        .{ TokenType.Less, "<" },
        .{ TokenType.GreaterEqual, ">=" },
        .{ TokenType.Greater, ">" },
    };

    for (tokens) |tuple| {
        var scanner = Scanner.init(tuple[1]);
        const result: Token = scanner.scan();
        const expected: Token = Token.init(&scanner, tuple[0]);

        try expectEqual(expected, result);
        try expectEqual(tuple[1].len, result.length);
    }
}

test "scan_unexpected_chars" {
    var scanner = Scanner.init("\\ 😇");
    const result: Token = scanner.scan();

    try expectEqual(TokenType.Error, result.token_type);
}
