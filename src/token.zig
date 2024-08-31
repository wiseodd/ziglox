const Scanner = @import("scanner.zig").Scanner;

pub const TokenType = enum {
    // Single-character tokens
    LeftParen,
    RightParen,
    LeftBrace,
    RightBrace,
    SemiColon,
    Comma,
    Dot,
    Minus,
    Plus,
    Slash,
    Star,
    // One- or two-character tokens
    Bang,
    BangEqual,
    Equal,
    EqualEqual,
    Greater,
    GreaterEqual,
    Less,
    LessEqual,
    // Literals
    Identifier,
    String,
    Number,
    // Keywords
    And,
    Class,
    Else,
    False,
    For,
    Fun,
    If,
    Nil,
    Or,
    Print,
    Return,
    Super,
    This,
    True,
    Var,
    While,
    // Etc.
    Error,
    EOF,
};

pub const Token = struct {
    token_type: TokenType,
    start: [*]const u8,
    length: usize,
    line: usize,

    pub fn init(scanner: *Scanner, token_type: TokenType) Token {
        return Token{
            .token_type = token_type,
            .start = scanner.start,
            .length = @intFromPtr(scanner.current) - @intFromPtr(scanner.start),
            .line = scanner.line,
        };
    }

    pub fn init_error(scanner: *Scanner, message: []const u8) Token {
        return Token{
            .token_type = TokenType.Error,
            .start = message.ptr,
            .length = message.len,
            .line = scanner.line,
        };
    }
};
