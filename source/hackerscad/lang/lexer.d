module hackerscad.lang.lexer;

import std.ascii : isDigit, isHexDigit, isAlpha, isAlphaNum, isWhite;
import std.conv : to;
import std.array : replace;

import hackerscad.lang.errors;

enum Tok
{
    eof,
    ident,
    intLit,
    floatLit,
    stringLit,
    interpLit,    /// "text $(expr) text": raw content, split by the parser
    // keywords
    kwModule, kwImport, kwEnum, kwImmutable, kwConst, kwAuto, kwStruct, kwReturn,
    kwIf, kwElse, kwForeach, kwForeachReverse, kwFor, kwWhile, kwBreak, kwContinue,
    kwSwitch, kwCase, kwDefault, kwUnittest, kwAssert, kwTrue, kwFalse, kwNull,
    kwPrivate, kwPublic, kwIn, kwIs, kwVoid,
    // punctuation
    lparen, rparen, lbracket, rbracket, lbrace, rbrace,
    comma, semicolon, colon, dot, dotdot, question, at, dollar, bang, arrow,
    assign, plusAssign, minusAssign, mulAssign, divAssign, modAssign, catAssign,
    andAssign, orAssign,
    plus, minus, mul, div, mod, tilde, pow,
    eq, ne, lt, le, gt, ge,
    andAnd, orOr, amp, pipe, caret,
    plusPlus, minusMinus,
}

immutable Tok[string] keywords;

shared static this()
{
    keywords = [
        "module": Tok.kwModule, "import": Tok.kwImport, "enum": Tok.kwEnum,
        "immutable": Tok.kwImmutable, "const": Tok.kwConst, "auto": Tok.kwAuto,
        "struct": Tok.kwStruct, "return": Tok.kwReturn, "if": Tok.kwIf, "else": Tok.kwElse,
        "foreach": Tok.kwForeach, "foreach_reverse": Tok.kwForeachReverse, "for": Tok.kwFor,
        "while": Tok.kwWhile, "break": Tok.kwBreak, "continue": Tok.kwContinue,
        "switch": Tok.kwSwitch, "case": Tok.kwCase, "default": Tok.kwDefault,
        "unittest": Tok.kwUnittest, "assert": Tok.kwAssert, "true": Tok.kwTrue,
        "false": Tok.kwFalse, "null": Tok.kwNull, "private": Tok.kwPrivate,
        "public": Tok.kwPublic, "in": Tok.kwIn, "is": Tok.kwIs, "void": Tok.kwVoid,
    ];
}

/// D keywords that this language does not support: using them gives a clear
/// error instead of a confusing parse failure.
immutable string[] unsupportedKeywords = [
    "class", "interface", "template", "mixin", "asm", "throw", "try", "catch",
    "finally", "new", "delete", "delegate", "function", "static", "goto", "with",
    "synchronized", "shared", "__gshared", "extern", "pragma", "union", "alias",
];

private struct Op
{
    string text;
    Tok kind;
}

/// Resolves the escapes of a "…" string: \n \t \r \0 \\ \" \' \$
string unescape(string content, Span span)
{
    string r;
    for (size_t i = 0; i < content.length; i++)
    {
        if (content[i] != '\\')
        {
            r ~= content[i];
            continue;
        }
        if (++i >= content.length)
            break;
        switch (content[i])
        {
        case 'n': r ~= '\n'; break;
        case 't': r ~= '\t'; break;
        case 'r': r ~= '\r'; break;
        case '0': r ~= '\0'; break;
        case '\\': r ~= '\\'; break;
        case '"': r ~= '"'; break;
        case '\'': r ~= '\''; break;
        case '$': r ~= '$'; break;
        default:
            throw new HcadError(Code.lex, "unknown escape sequence '\\" ~ content[i] ~ "'", span);
        }
    }
    return r;
}

struct Token
{
    Tok kind;
    string text;   /// identifier name, decoded string, or literal digits
    Span span;
}

/// `line`/`col` place the source inside a larger file (interpolations).
Token[] lex(string source, string file, uint startLine = 1, uint startCol = 1)
{
    Token[] toks;
    size_t i = 0;
    uint line = startLine, col = startCol;

    Span here(size_t len = 1) => Span(file, line, col, cast(uint) len);

    void advance(size_t n = 1)
    {
        foreach (_; 0 .. n)
        {
            if (i < source.length && source[i] == '\n')
            {
                line++;
                col = 1;
            }
            else
                col++;
            i++;
        }
    }

    char peek(size_t o = 0) => i + o < source.length ? source[i + o] : '\0';

    while (true)
    {
        // whitespace and comments
        while (i < source.length)
        {
            if (isWhite(peek))
                advance();
            else if (peek == '/' && peek(1) == '/')
                while (i < source.length && peek != '\n')
                    advance();
            else if (peek == '/' && peek(1) == '*')
            {
                auto start = here(2);
                advance(2);
                while (i < source.length && !(peek == '*' && peek(1) == '/'))
                    advance();
                if (i >= source.length)
                    throw new HcadError(Code.lex, "unterminated /* comment", start);
                advance(2);
            }
            else if (peek == '/' && peek(1) == '+')
            {
                auto start = here(2);
                int depth = 0;
                do
                {
                    if (peek == '/' && peek(1) == '+')
                    {
                        depth++;
                        advance(2);
                    }
                    else if (peek == '+' && peek(1) == '/')
                    {
                        depth--;
                        advance(2);
                    }
                    else if (i >= source.length)
                        throw new HcadError(Code.lex, "unterminated /+ comment", start);
                    else
                        advance();
                }
                while (depth > 0);
            }
            else
                break;
        }

        if (i >= source.length)
        {
            toks ~= Token(Tok.eof, "", here(0));
            return toks;
        }

        immutable c = peek;
        immutable startI = i;
        auto span = here();

        if (c == '`' || (c == 'r' && peek(1) == '"'))
        {
            // WYSIWYG strings, as in D: no escapes, no interpolation
            if (c == 'r')
                advance();
            immutable quote = peek;
            advance();
            immutable from = i;
            while (true)
            {
                if (i >= source.length)
                    throw new HcadError(Code.lex, "unterminated string literal", span);
                if (peek == quote)
                    break;
                advance();
            }
            auto content = source[from .. i];
            advance();
            span.length = cast(uint)(i - startI);
            toks ~= Token(Tok.stringLit, content, span);
            continue;
        }

        if (c == '"')
        {
            // "…": escapes, and $(expr) interpolation (the parser splits it);
            // quotes inside $(…) belong to the expression
            advance();
            immutable from = i;
            int depth;          // inside $( … ) when > 0
            bool interpolated;
            while (true)
            {
                if (i >= source.length)
                    throw new HcadError(Code.lex, "unterminated string literal", span);
                immutable ch = peek;
                if (depth == 0)
                {
                    if (ch == '"')
                        break;
                    if (ch == '\\')
                    {
                        advance(2);
                        continue;
                    }
                    if (ch == '$' && peek(1) == '(')
                    {
                        interpolated = true;
                        depth = 1;
                        advance(2);
                        continue;
                    }
                    advance();
                    continue;
                }
                if (ch == '"')
                {
                    // a string inside the expression
                    advance();
                    while (i < source.length && peek != '"')
                        advance(peek == '\\' ? 2 : 1);
                    advance();
                    continue;
                }
                if (ch == '(')
                    depth++;
                else if (ch == ')')
                    depth--;
                advance();
            }
            auto content = source[from .. i];
            advance();
            span.length = cast(uint)(i - startI);
            if (interpolated)
                toks ~= Token(Tok.interpLit, content, span);
            else
                toks ~= Token(Tok.stringLit, unescape(content, span), span);
            continue;
        }

        if (isAlpha(c) || c == '_')
        {
            while (isAlphaNum(peek) || peek == '_')
                advance();
            auto word = source[startI .. i];
            span.length = cast(uint) word.length;
            if (auto k = word in keywords)
                toks ~= Token(*k, word, span);
            else
            {
                foreach (u; unsupportedKeywords)
                    if (u == word)
                        throw new HcadError(Code.syntax, "'" ~ word ~ "' is not supported in .hcad files", span);
                toks ~= Token(Tok.ident, word, span);
            }
            continue;
        }

        if (isDigit(c))
        {
            bool isFloat = false;
            if (c == '0' && (peek(1) == 'x' || peek(1) == 'X'))
            {
                advance(2);
                while (isHexDigit(peek) || peek == '_')
                    advance();
                auto digits = source[startI + 2 .. i].replace("_", "");
                span.length = cast(uint)(i - startI);
                toks ~= Token(Tok.intLit, digits.to!long(16).to!string, span);
                continue;
            }
            while (isDigit(peek) || peek == '_')
                advance();
            // "1.5" is a float, "1..5" a range and "60.mm" a UFCS call
            if (peek == '.' && isDigit(peek(1)))
            {
                isFloat = true;
                advance();
                while (isDigit(peek) || peek == '_')
                    advance();
            }
            if ((peek == 'e' || peek == 'E') && (isDigit(peek(1)) || ((peek(1) == '-' || peek(1) == '+') && isDigit(peek(2)))))
            {
                isFloat = true;
                advance(2);
                while (isDigit(peek))
                    advance();
            }
            span.length = cast(uint)(i - startI);
            toks ~= Token(isFloat ? Tok.floatLit : Tok.intLit, source[startI .. i].replace("_", ""), span);
            continue;
        }

        static immutable Op[] ops = [
            Op("..", Tok.dotdot), Op("=>", Tok.arrow), Op("==", Tok.eq), Op("!=", Tok.ne),
            Op("<=", Tok.le), Op(">=", Tok.ge), Op("&&", Tok.andAnd), Op("||", Tok.orOr),
            Op("+=", Tok.plusAssign), Op("-=", Tok.minusAssign), Op("*=", Tok.mulAssign),
            Op("/=", Tok.divAssign), Op("%=", Tok.modAssign), Op("~=", Tok.catAssign),
            Op("&=", Tok.andAssign), Op("|=", Tok.orAssign), Op("^^", Tok.pow),
            Op("++", Tok.plusPlus), Op("--", Tok.minusMinus),
            Op("(", Tok.lparen), Op(")", Tok.rparen), Op("[", Tok.lbracket), Op("]", Tok.rbracket),
            Op("{", Tok.lbrace), Op("}", Tok.rbrace), Op(",", Tok.comma), Op(";", Tok.semicolon),
            Op(":", Tok.colon), Op(".", Tok.dot), Op("?", Tok.question), Op("@", Tok.at),
            Op("$", Tok.dollar), Op("!", Tok.bang), Op("=", Tok.assign), Op("+", Tok.plus),
            Op("-", Tok.minus), Op("*", Tok.mul), Op("/", Tok.div), Op("%", Tok.mod),
            Op("~", Tok.tilde), Op("<", Tok.lt), Op(">", Tok.gt), Op("&", Tok.amp),
            Op("|", Tok.pipe), Op("^", Tok.caret),
        ];
        bool matched = false;
        foreach (op; ops)
            if (source.length - i >= op.text.length && source[i .. i + op.text.length] == op.text)
            {
                span.length = cast(uint) op.text.length;
                advance(op.text.length);
                toks ~= Token(op.kind, op.text, span);
                matched = true;
                break;
            }
        if (!matched)
            throw new HcadError(Code.lex, "unexpected character '" ~ c ~ "'", span);
    }
}

unittest
{
    import std.algorithm : map;
    import std.array : array;

    auto t = lex(`@param enum w = 60.mm; x[1 .. $] /+ a /+ b +/ +/ "a\n" 2.5e3 0xFF 1_000`, "t");
    assert(t.map!(x => x.kind).array == [
        Tok.at, Tok.ident, Tok.kwEnum, Tok.ident, Tok.assign, Tok.intLit, Tok.dot, Tok.ident, Tok.semicolon,
        Tok.ident, Tok.lbracket, Tok.intLit, Tok.dotdot, Tok.dollar, Tok.rbracket,
        Tok.stringLit, Tok.floatLit, Tok.intLit, Tok.intLit, Tok.eof]);
    assert(t[15].text == "a\n");
    auto it = lex(`"a $(f("x")) \$(c)" `~"`raw $(x)`", "t");
    assert(it[0].kind == Tok.interpLit && it[0].text == `a $(f("x")) \$(c)`, it[0].text);
    assert(it[1].kind == Tok.stringLit && it[1].text == "raw $(x)");
    assert(t[17].text == "255" && t[18].text == "1000");
    assert(t[3].span.line == 1 && t[3].span.col == 13);

    auto u = lex("1.5.mm", "t");
    assert(u[0].kind == Tok.floatLit && u[1].kind == Tok.dot && u[2].text == "mm");

    import std.exception : assertThrown;
    assertThrown!HcadError(lex("class Foo {}", "t"));
    assertThrown!HcadError(lex(`"open`, "t"));
}
