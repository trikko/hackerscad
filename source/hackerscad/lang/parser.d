module hackerscad.lang.parser;

import std.conv : to;
import std.format : format;

import hackerscad.lang.lexer;
import hackerscad.lang.ast;
import hackerscad.lang.errors;

Program parse(string source, string file)
{
    auto p = Parser(lex(source, file), file);
    return p.parseProgram();
}

/// Parses a single expression (used for -D overrides from the command line).
Expr parseExpression(string source, string file)
{
    auto p = Parser(lex(source, file), file);
    auto e = p.parseExpr();
    p.expect(Tok.eof, "end of expression");
    return e;
}

private:

struct Parser
{
    Token[] toks;
    string file;
    size_t pos;

    ref const(Token) cur() const => toks[pos];
    Tok kind(size_t ahead = 0) const => toks[pos + ahead < toks.length ? pos + ahead : $ - 1].kind;

    Token advance()
    {
        auto t = toks[pos];
        if (pos + 1 < toks.length)
            pos++;
        return t;
    }

    bool accept(Tok k)
    {
        if (kind == k)
        {
            advance();
            return true;
        }
        return false;
    }

    Token expect(Tok k, string what)
    {
        if (kind != k)
            error(format("expected %s, found %s", what, describe(cur)));
        return advance();
    }

    noreturn error(string msg, string suggestion = null)
    {
        throw new HcadError(Code.syntax, msg, cur.span, suggestion);
    }

    static string describe(const Token t)
    {
        if (t.kind == Tok.eof) return "end of file";
        if (t.kind == Tok.ident) return "'" ~ t.text ~ "'";
        if (t.kind == Tok.stringLit || t.kind == Tok.interpLit) return "string literal";
        return "'" ~ t.text ~ "'";
    }

    T node(T)(Span span)
    {
        auto n = new T;
        n.span = span;
        return n;
    }

    // ------------------------------------------------------------ declarations

    Program parseProgram()
    {
        auto prog = new Program;
        prog.file = file;
        auto attrs = parseAttributes();
        if (kind == Tok.kwModule)
        {
            auto m = node!ModuleDecl(cur.span);
            advance();
            m.attrs = attrs;
            m.name = parseDottedName();
            expect(Tok.semicolon, "';' after module declaration");
            prog.moduleDecl = m;
            attrs = null;
        }
        while (kind != Tok.eof)
        {
            prog.decls ~= parseDeclaration(attrs);
            attrs = null;
        }
        return prog;
    }

    Attribute[] parseAttributes()
    {
        Attribute[] r;
        while (kind == Tok.at)
        {
            auto span = cur.span;
            advance();
            auto name = expect(Tok.ident, "attribute name after '@'").text;
            Arg[] args;
            if (kind == Tok.lparen)
                args = parseArgs();
            r ~= Attribute(name, args, span);
        }
        return r;
    }

    string[] parseDottedName()
    {
        string[] r = [expect(Tok.ident, "name").text];
        while (accept(Tok.dot))
            r ~= expect(Tok.ident, "name after '.'").text;
        return r;
    }

    Stmt parseDeclaration(Attribute[] attrs = null)
    {
        attrs ~= parseAttributes();
        bool isPrivate = false, isPublic = false;
        if (kind == Tok.kwPrivate || kind == Tok.kwPublic)
        {
            isPrivate = advance().kind == Tok.kwPrivate;
            isPublic = !isPrivate;
            attrs ~= parseAttributes();
        }

        // annotations mean something only on functions and variables: anywhere else they
        // would be dropped without a word
        void noAttributes(string what)
        {
            if (!attrs.length)
                return;
            auto a = attrs[0];
            throw new HcadError(Code.syntax, a.name == "unit"
                ? format("'@unit' cannot be put before %s: it sets the unit of a whole file, before its module "
                    ~ "line (@unit(inch) module m;)", what)
                : format("'@%s' cannot be put before %s: annotations go on functions and immutables", a.name, what),
                a.span);
        }

        switch (kind)
        {
        case Tok.kwImport:
            noAttributes("an import");
            return parseImport(isPublic);
        case Tok.kwUnittest:
            noAttributes("a unittest");
            {
                auto u = node!Unittest(cur.span);
                advance();
                u.body = parseBlock();
                return u;
            }
        case Tok.kwStruct:
            noAttributes("a struct");
            return parseStruct(isPrivate);
        default:
            auto s = parseStatement(attrs, true);
            if (auto v = cast(VarDecl) s)
                v.isPrivate = isPrivate;
            else if (auto f = cast(FuncDecl) s)
                f.isPrivate = isPrivate;
            else if (attrs.length)
                throw new HcadError(Code.syntax, "attributes can only be applied to declarations", attrs[0].span);
            return s;
        }
    }

    /// `import a;`, `import a, b.c;`, `import x = a;`, `import a : f, g;`;
    /// several modules give a group of imports.
    Stmt parseImport(bool isPublic = false)
    {
        auto first = cur.span;
        advance();
        ImportDecl[] all;
        while (true)
        {
            auto d = node!ImportDecl(cur.span);
            d.isPublic = isPublic;
            if (kind == Tok.ident && kind(1) == Tok.assign)
            {
                d.aliasName = advance().text;
                advance();
            }
            d.path = parseDottedName();
            all ~= d;
            if (accept(Tok.colon))
            {
                do
                    d.selective ~= expect(Tok.ident, "imported name").text;
                while (accept(Tok.comma));
                break;
            }
            if (!accept(Tok.comma))
                break;
        }
        expect(Tok.semicolon, "';' after import");
        if (all.length == 1)
            return all[0];
        auto b = node!Block(first);
        b.scoped = false;
        foreach (d; all)
            b.stmts ~= d;
        return b;
    }

    StructDecl parseStruct(bool isPrivate)
    {
        auto s = node!StructDecl(cur.span);
        advance();
        s.isPrivate = isPrivate;
        s.name = expect(Tok.ident, "struct name").text;
        expect(Tok.lbrace, "'{' after struct name");
        while (!accept(Tok.rbrace))
        {
            if (kind == Tok.eof)
                error("unterminated struct body");
            auto attrs = parseAttributes();
            auto d = parseStatement(attrs, true);
            if (auto f = cast(FuncDecl) d)
                s.methods ~= f;
            else if (auto v = cast(VarDecl) d)
                s.fields ~= v;
            else if (auto b = cast(Block) d)
            {
                // `Length d, tap;` expands into several declarations
                foreach (x; b.stmts)
                    s.fields ~= cast(VarDecl) x;
            }
            else
                throw new HcadError(Code.syntax, "only fields and methods are allowed in a struct", d.span);
        }
        return s;
    }

    // ------------------------------------------------------------ types

    /// Tries to parse a type at the current position; returns null and
    /// restores the position when the tokens are not a type.
    TypeRef tryParseType()
    {
        if (kind != Tok.ident)
            return null;
        auto start = pos;
        auto t = new TypeRef;
        t.span = cur.span;
        t.name = advance().text;
        while (kind == Tok.lbracket)
        {
            if (kind(1) == Tok.rbracket)
            {
                advance();
                advance();
                auto a = new TypeRef;
                a.span = t.span;
                a.elem = t;
                t = a;
            }
            else if (kind(1) == Tok.ident && kind(2) == Tok.rbracket)
            {
                advance();
                auto k = new TypeRef;
                k.span = cur.span;
                k.name = advance().text;
                advance();
                auto a = new TypeRef;
                a.span = t.span;
                a.elem = t;
                a.key = k;
                t = a;
            }
            else
            {
                pos = start;
                return null;
            }
        }
        return t;
    }

    // ------------------------------------------------------------ statements

    /// Is the current position the start of `Type name …` ?
    bool looksLikeTypedDecl()
    {
        auto save = pos;
        scope (exit)
            pos = save;
        if (tryParseType() is null)
            return false;
        if (kind != Tok.ident)
            return false;
        auto k = kind(1);
        return k == Tok.assign || k == Tok.semicolon || k == Tok.comma || k == Tok.lparen;
    }

    Stmt parseStatement(Attribute[] attrs = null, bool topLevel = false)
    {
        if (++nesting > maxNesting)
            throw new HcadError(Code.limit, format("blocks nested more than %d levels deep", maxNesting), cur.span);
        scope (exit)
            nesting--;
        if (!topLevel && kind == Tok.at)
            attrs ~= parseAttributes();
        auto span = cur.span;
        switch (kind)
        {
        case Tok.lbrace:
            return parseBlock();
        case Tok.semicolon:
            advance();
            return node!Block(span);
        case Tok.kwEnum:
            // enum is reserved for enumerations; constants are immutable
            if (kind(1) == Tok.ident && kind(2) == Tok.lbrace || kind(1) == Tok.lbrace)
                error("enumerations are not supported yet");
            error("use 'immutable' for constants ('enum' is reserved for enumerations)");
        case Tok.kwImmutable:
        case Tok.kwConst:
        case Tok.kwAuto:
            {
                auto storage = kind == Tok.kwImmutable ? Storage.immutable_ : kind == Tok.kwConst ? Storage.const_ : Storage.auto_;
                advance();
                TypeRef type;
                if (!(kind == Tok.ident && (kind(1) == Tok.assign || kind(1) == Tok.lparen)))
                    type = tryParseType();
                if (kind == Tok.ident && kind(1) == Tok.lparen)
                {
                    if (storage != Storage.auto_)
                        error("functions cannot be declared enum, immutable or const");
                    return parseFunction(attrs, type, span);
                }
                return parseVarDecls(attrs, storage, type, span);
            }
        case Tok.kwVoid:
            {
                advance();
                auto t = new TypeRef;
                t.name = "void";
                t.span = span;
                return parseFunction(attrs, t, span);
            }
        case Tok.kwIf:
            return parseIf();
        case Tok.kwForeach:
        case Tok.kwForeachReverse:
            return parseForeach();
        case Tok.kwFor:
            return parseFor();
        case Tok.kwWhile:
            {
                auto w = node!While(span);
                advance();
                expect(Tok.lparen, "'(' after while");
                w.cond = parseExpr();
                expect(Tok.rparen, "')'");
                w.body = parseStatement();
                return w;
            }
        case Tok.kwReturn:
            {
                auto r = node!Return(span);
                advance();
                if (kind != Tok.semicolon)
                    r.value = parseExpr();
                expect(Tok.semicolon, "';' after return");
                return r;
            }
        case Tok.kwBreak:
            advance();
            expect(Tok.semicolon, "';' after break");
            return node!Break(span);
        case Tok.kwContinue:
            advance();
            expect(Tok.semicolon, "';' after continue");
            return node!Continue(span);
        case Tok.kwAssert:
            {
                auto a = node!AssertStmt(span);
                advance();
                expect(Tok.lparen, "'(' after assert");
                a.cond = parseExpr();
                if (accept(Tok.comma))
                    a.message = parseExpr();
                expect(Tok.rparen, "')'");
                expect(Tok.semicolon, "';' after assert");
                return a;
            }
        case Tok.kwSwitch:
            return parseSwitch();
        case Tok.kwImport:
            return parseImport();
        case Tok.kwStruct:
            return parseStruct(false);
        default:
            break;
        }

        if (looksLikeTypedDecl())
        {
            auto type = tryParseType();
            if (kind(1) == Tok.lparen)
                return parseFunction(attrs, type, span);
            return parseVarDecls(attrs, Storage.auto_, type, span);
        }

        if (attrs.length)
            throw new HcadError(Code.syntax, "attributes can only be applied to declarations", attrs[0].span);
        auto s = node!ExprStmt(span);
        s.expr = parseExpr();
        expect(Tok.semicolon, "';' after expression");
        return s;
    }

    Stmt parseVarDecls(Attribute[] attrs, Storage storage, TypeRef type, Span span)
    {
        VarDecl[] decls;
        do
        {
            auto v = node!VarDecl(span);
            v.attrs = attrs;
            v.storage = storage;
            v.type = type;
            auto name = expect(Tok.ident, "variable name");
            v.name = name.text;
            v.nameSpan = name.span;
            if (accept(Tok.assign))
                v.init = parseAssignExpr();
            else if (type is null)
                error("a declaration without a type needs an initializer");
            decls ~= v;
        }
        while (accept(Tok.comma));
        expect(Tok.semicolon, "';' after declaration");
        if (decls.length == 1)
            return decls[0];
        auto b = node!Block(span);
        b.scoped = false;
        foreach (d; decls)
            b.stmts ~= d;
        return b;
    }

    FuncDecl parseFunction(Attribute[] attrs, TypeRef returnType, Span span)
    {
        auto f = node!FuncDecl(span);
        f.attrs = attrs;
        f.returnType = returnType;
        auto name = expect(Tok.ident, "function name");
        f.name = name.text;
        f.nameSpan = name.span;
        f.params = parseParams(true);
        if (accept(Tok.arrow))
        {
            f.exprBody = parseExpr();
            expect(Tok.semicolon, "';' after function expression");
        }
        else
            f.body = parseBlock();
        return f;
    }

    Param[] parseParams(bool typesRequired)
    {
        expect(Tok.lparen, "'(' to start the parameter list");
        Param[] ps;
        while (kind != Tok.rparen)
        {
            Param p;
            p.span = cur.span;
            if (kind == Tok.ident && (kind(1) == Tok.comma || kind(1) == Tok.rparen || kind(1) == Tok.assign))
            {
                if (typesRequired)
                    error(format("parameter '%s' needs a type (e.g. 'Length %s')", cur.text, cur.text));
            }
            else
            {
                if (!accept(Tok.kwAuto))
                {
                    p.type = tryParseType();
                    if (p.type is null)
                        error("expected a parameter");
                }
            }
            p.name = expect(Tok.ident, "parameter name").text;
            if (accept(Tok.assign))
                p.defaultValue = parseAssignExpr();
            ps ~= p;
            if (!accept(Tok.comma))
                break;
        }
        expect(Tok.rparen, "')' to close the parameter list");
        return ps;
    }

    Block parseBlock()
    {
        auto b = node!Block(cur.span);
        expect(Tok.lbrace, "'{'");
        while (kind != Tok.rbrace)
        {
            if (kind == Tok.eof)
                throw new HcadError(Code.syntax, "unterminated block: missing '}'", b.span);
            b.stmts ~= parseStatement();
        }
        b.endLine = cur.span.line;
        advance();
        return b;
    }

    If parseIf()
    {
        auto s = node!If(cur.span);
        advance();
        expect(Tok.lparen, "'(' after if");
        s.cond = parseExpr();
        expect(Tok.rparen, "')'");
        s.then = parseStatement();
        if (accept(Tok.kwElse))
            s.otherwise = parseStatement();
        return s;
    }

    Foreach parseForeach()
    {
        auto f = node!Foreach(cur.span);
        f.reverse = advance().kind == Tok.kwForeachReverse;
        expect(Tok.lparen, "'(' after foreach");
        Param[] vars;
        do
        {
            Param p;
            p.span = cur.span;
            if (!(kind == Tok.ident && (kind(1) == Tok.comma || kind(1) == Tok.semicolon)) && !accept(Tok.kwAuto))
                p.type = tryParseType();
            p.name = expect(Tok.ident, "loop variable").text;
            vars ~= p;
        }
        while (accept(Tok.comma));
        if (vars.length > 2)
            error("foreach takes at most two variables");
        expect(Tok.semicolon, "';' after the foreach variables");
        if (vars.length == 2)
            f.key = vars[0];
        f.value = vars[$ - 1];
        f.aggregate = parseExpr();
        if (accept(Tok.dotdot))
        {
            if (vars.length != 1)
                error("a range foreach takes a single variable");
            f.hi = parseExpr();
        }
        expect(Tok.rparen, "')'");
        f.body = parseStatement();
        return f;
    }

    For parseFor()
    {
        auto f = node!For(cur.span);
        advance();
        expect(Tok.lparen, "'(' after for");
        if (!accept(Tok.semicolon))
            f.init = parseStatement();
        if (kind != Tok.semicolon)
            f.cond = parseExpr();
        expect(Tok.semicolon, "';'");
        if (kind != Tok.rparen)
            f.step = parseExpr();
        expect(Tok.rparen, "')'");
        f.body = parseStatement();
        return f;
    }

    Switch parseSwitch()
    {
        auto s = node!Switch(cur.span);
        advance();
        expect(Tok.lparen, "'(' after switch");
        s.subject = parseExpr();
        expect(Tok.rparen, "')'");
        expect(Tok.lbrace, "'{'");
        while (!accept(Tok.rbrace))
        {
            Expr[] values;
            if (accept(Tok.kwDefault))
                expect(Tok.colon, "':' after default");
            else
            {
                expect(Tok.kwCase, "'case' or 'default'");
                do
                    values ~= parseAssignExpr();
                while (accept(Tok.comma));
                expect(Tok.colon, "':' after case");
            }
            Stmt[] body;
            while (kind != Tok.kwCase && kind != Tok.kwDefault && kind != Tok.rbrace)
            {
                if (kind == Tok.eof)
                    error("unterminated switch");
                body ~= parseStatement();
            }
            s.caseValues ~= values;
            s.caseBodies ~= body;
        }
        return s;
    }

    // ------------------------------------------------------------ expressions

    /// Expressions and statements inside one another: deep enough for any
    /// model, low enough that the parser's own recursion stays on the stack.
    enum maxNesting = 2000;
    uint nesting;

    Expr parseExpr()
    {
        if (++nesting > maxNesting)
            throw new HcadError(Code.limit, format("expression nested more than %d levels deep", maxNesting), cur.span);
        scope (exit)
            nesting--;
        return parseAssignExpr();
    }

    Expr parseAssignExpr()
    {
        auto left = parseTernary();
        switch (kind)
        {
        case Tok.assign, Tok.plusAssign, Tok.minusAssign, Tok.mulAssign, Tok.divAssign,
            Tok.modAssign, Tok.catAssign, Tok.andAssign, Tok.orAssign:
            auto a = node!Assign(cur.span);
            a.op = advance().kind;
            a.target = left;
            a.value = parseAssignExpr();
            return a;
        default:
            return left;
        }
    }

    Expr parseTernary()
    {
        auto c = parseBinary(0);
        if (kind != Tok.question)
            return c;
        auto t = node!Ternary(cur.span);
        advance();
        t.cond = c;
        t.then = parseAssignExpr();
        expect(Tok.colon, "':' in conditional expression");
        t.otherwise = parseTernary();
        return t;
    }

    static int precedence(Tok k)
    {
        switch (k)
        {
        case Tok.orOr: return 1;
        case Tok.andAnd: return 2;
        case Tok.pipe: return 3;
        case Tok.caret: return 4;
        case Tok.amp: return 5;
        case Tok.eq, Tok.ne, Tok.lt, Tok.le, Tok.gt, Tok.ge, Tok.kwIn, Tok.kwIs: return 6;
        case Tok.plus, Tok.minus, Tok.tilde: return 7;
        case Tok.mul, Tok.div, Tok.mod: return 8;
        default: return -1;
        }
    }

    Expr parseBinary(int minPrec)
    {
        auto left = parseUnary();
        while (true)
        {
            immutable prec = precedence(kind);
            if (prec < 0 || prec < minPrec)
                break;
            auto b = node!Binary(cur.span);
            b.op = advance().kind;
            b.left = left;
            b.right = parseBinary(prec + 1);
            left = b;
        }
        return left;
    }

    Expr parseUnary()
    {
        switch (kind)
        {
        case Tok.minus, Tok.plus, Tok.bang, Tok.amp:
            {
                auto u = node!Unary(cur.span);
                u.op = advance().kind;
                u.operand = parseUnary();
                return u;
            }
        case Tok.plusPlus, Tok.minusMinus:
            {
                auto u = node!IncDec(cur.span);
                u.increment = advance().kind == Tok.plusPlus;
                u.prefix = true;
                u.target = parseUnary();
                return u;
            }
        default:
            return parsePow();
        }
    }

    Expr parsePow()
    {
        auto base = parsePostfix(parsePrimary());
        if (kind != Tok.pow)
            return base;
        auto b = node!Binary(cur.span);
        b.op = advance().kind;
        b.left = base;
        b.right = parseUnary(); // right associative, binds tighter than unary minus on the left
        return b;
    }

    Expr parsePostfix(Expr e)
    {
        while (true)
        {
            switch (kind)
            {
            case Tok.dot:
                {
                    auto m = node!Member(cur.span);
                    advance();
                    auto name = expect(Tok.ident, "member name after '.'");
                    m.object = e;
                    m.name = name.text;
                    m.nameSpan = name.span;
                    e = m;
                    break;
                }
            case Tok.lparen:
                {
                    auto c = node!Call(cur.span);
                    c.callee = e;
                    c.args = parseArgs();
                    e = c;
                    break;
                }
            case Tok.bang:
                {
                    // template instantiation: f!(a, b) or f!x, optionally followed by (args)
                    auto c = node!Call(cur.span);
                    advance();
                    c.callee = e;
                    if (accept(Tok.lparen))
                    {
                        while (kind != Tok.rparen)
                        {
                            c.templateArgs ~= parseAssignExpr();
                            if (!accept(Tok.comma))
                                break;
                        }
                        expect(Tok.rparen, "')' after template arguments");
                    }
                    else
                        c.templateArgs ~= parsePrimary();
                    if (kind == Tok.lparen)
                        c.args = parseArgs();
                    else
                        c.hasParens = false;
                    e = c;
                    break;
                }
            case Tok.lbracket:
                {
                    auto span = cur.span;
                    advance();
                    if (accept(Tok.rbracket))
                    {
                        auto s = node!Slice(span);
                        s.object = e;
                        e = s;
                        break;
                    }
                    auto first = parseAssignExpr();
                    if (accept(Tok.dotdot))
                    {
                        auto s = node!Slice(span);
                        s.object = e;
                        s.lo = first;
                        s.hi = parseAssignExpr();
                        expect(Tok.rbracket, "']'");
                        e = s;
                        break;
                    }
                    auto ix = node!Index(span);
                    ix.object = e;
                    ix.indices ~= first;
                    while (accept(Tok.comma))
                        ix.indices ~= parseAssignExpr();
                    expect(Tok.rbracket, "']'");
                    e = ix;
                    break;
                }
            case Tok.plusPlus, Tok.minusMinus:
                {
                    auto u = node!IncDec(cur.span);
                    u.increment = advance().kind == Tok.plusPlus;
                    u.target = e;
                    e = u;
                    break;
                }
            default:
                return e;
            }
        }
    }

    Arg[] parseArgs()
    {
        expect(Tok.lparen, "'('");
        Arg[] args;
        bool seenNamed;
        while (kind != Tok.rparen)
        {
            Arg a;
            a.span = cur.span;
            if (kind == Tok.ident && kind(1) == Tok.colon)
            {
                a.name = advance().text;
                advance();
                seenNamed = true;
            }
            else if (seenNamed)
                error("positional arguments cannot follow named arguments");
            a.value = parseAssignExpr();
            args ~= a;
            if (!accept(Tok.comma))
                break;
        }
        expect(Tok.rparen, "')' to close the argument list");
        return args;
    }

    /// At '(' : is this the parameter list of a lambda?
    bool lambdaAhead()
    {
        size_t depth = 0, i = pos;
        for (; i < toks.length; i++)
        {
            if (toks[i].kind == Tok.lparen)
                depth++;
            else if (toks[i].kind == Tok.rparen && --depth == 0)
                break;
            else if (toks[i].kind == Tok.eof)
                return false;
        }
        return i + 1 < toks.length && (toks[i + 1].kind == Tok.arrow || toks[i + 1].kind == Tok.lbrace);
    }

    /// Splits `text $(expr) text` and parses each expression where it
    /// stands in the file, so errors point at the right column.
    Expr parseInterpolation(Token t)
    {
        auto n = node!InterpString(t.span);
        auto src = t.text;
        uint line = t.span.line, col = t.span.col + 1;   // after the opening quote
        string part;
        size_t i = 0;
        void step()
        {
            if (src[i] == '\n')
            {
                line++;
                col = 1;
            }
            else if (!continuesChar(src[i]))
                col++;
            i++;
        }

        while (i < src.length)
        {
            if (src[i] == '\\' && i + 1 < src.length)
            {
                // escapes in the literal parts
                part ~= unescape(src[i .. i + 2], Span(file, line, col, 2));
                step();
                step();
                continue;
            }
            if (src[i] == '$' && i + 1 < src.length && src[i + 1] == '(')
            {
                auto startLine = line, startCol = col + 2;
                step();
                step();
                immutable from = i;
                int depth = 1;
                char quote = 0;
                while (i < src.length)
                {
                    immutable ch = src[i];
                    if (quote)
                    {
                        if (ch == '\\')
                            step();
                        else if (ch == quote)
                            quote = 0;
                    }
                    else if (ch == '"')
                        quote = ch;
                    else if (ch == '(')
                        depth++;
                    else if (ch == ')' && --depth == 0)
                        break;
                    step();
                }
                if (i >= src.length)
                    throw new HcadError(Code.syntax, "unterminated $( in string", Span(file, startLine, startCol - 2, 2));
                auto sub = Parser(lex(src[from .. i], file, startLine, startCol), file);
                auto e = sub.parseExpr();
                sub.expect(Tok.eof, "')' to close $(");
                step(); // the closing parenthesis
                n.parts ~= part;
                n.exprs ~= e;
                part = null;
                continue;
            }
            part ~= src[i];
            step();
        }
        n.parts ~= part;
        return n;
    }

    Expr parsePrimary()
    {
        auto span = cur.span;
        switch (kind)
        {
        case Tok.intLit, Tok.floatLit, Tok.stringLit, Tok.kwTrue, Tok.kwFalse, Tok.kwNull:
            {
                auto l = node!Literal(span);
                auto t = advance();
                l.text = t.text;
                l.type = t.kind == Tok.intLit ? Literal.Type.int_ : t.kind == Tok.floatLit ? Literal.Type.float_
                    : t.kind == Tok.stringLit ? Literal.Type.string_ : t.kind == Tok.kwTrue ? Literal.Type.true_
                    : t.kind == Tok.kwFalse ? Literal.Type.false_ : Literal.Type.null_;
                return l;
            }
        case Tok.interpLit:
            return parseInterpolation(advance());
        case Tok.ident:
            {
                if (kind(1) == Tok.arrow)
                {
                    auto l = node!Lambda(span);
                    Param p;
                    p.span = span;
                    p.name = advance().text;
                    advance();
                    l.params = [p];
                    l.exprBody = parseAssignExpr();
                    return l;
                }
                auto id = node!Ident(span);
                id.name = advance().text;
                return id;
            }
        case Tok.dollar:
            advance();
            return node!Dollar(span);
        case Tok.lparen:
            {
                if (lambdaAhead())
                {
                    auto l = node!Lambda(span);
                    l.params = parseParams(false);
                    if (accept(Tok.arrow))
                        l.exprBody = parseAssignExpr();
                    else
                        l.blockBody = parseBlock();
                    return l;
                }
                advance();
                auto e = parseExpr();
                expect(Tok.rparen, "')'");
                return e;
            }
        case Tok.lbracket:
            {
                advance();
                if (accept(Tok.rbracket))
                    return node!ArrayLit(span);
                auto first = parseAssignExpr();
                if (accept(Tok.colon))
                {
                    auto aa = node!AssocLit(span);
                    aa.keys ~= first;
                    aa.values ~= parseAssignExpr();
                    while (accept(Tok.comma) && kind != Tok.rbracket)
                    {
                        aa.keys ~= parseAssignExpr();
                        expect(Tok.colon, "':' in associative array literal");
                        aa.values ~= parseAssignExpr();
                    }
                    expect(Tok.rbracket, "']'");
                    return aa;
                }
                auto arr = node!ArrayLit(span);
                arr.elems ~= first;
                while (accept(Tok.comma) && kind != Tok.rbracket)
                    arr.elems ~= parseAssignExpr();
                expect(Tok.rbracket, "']'");
                return arr;
            }
        default:
            error("expected an expression, found " ~ describe(cur));
        }
    }
}

unittest
{
    auto p = parse(`
        @unit(inch) module test;
        import std.shapes;
        import c = lib.hinges;
        import std.hardware : M3, M4;

        @param("Width", min: 20.mm) @preset("wide", 90.mm) immutable width = 60.mm;
        immutable xs = [1, 2, 3];

        struct Screw { Length d, tap; string name = "x"; Length head() => d * 2; }

        Solid colonna(Length h, Screw vite = M3)
        {
            return cylinder(d: vite.d * 2.2, h: h) - cylinder(d: vite.tap, h: h);
        }

        @part("steelblue") Solid body()
        {
            auto s = box(width, 40, 25).fillet(edges.filter(e => e.isParallel(Z)), r: 5.mm);
            Length[] gaps;
            foreach (i, sx; [-1, 1])
                foreach (j; 0 .. 2)
                    s += colonna(1).move(x: sx * 2, y: j);
            for (int k = 0; k < 3; k++) {}
            auto f = (a, b) => a + b;
            auto g = (Length a) { return a * 2; };
            return i > 0 ? s : s & s;
        }

        double sq(double x) => x ^^ 2;
        unittest { assert(body.bbox.size.z <= 40.mm, "drawer"); }
    `, "test.hcad");
    assert(p.moduleDecl.name == ["test"]);
    assert(p.moduleDecl.attrs[0].name == "unit");
    assert(p.decls.length == 10);
    auto imp = cast(ImportDecl) p.decls[1];
    assert(imp.aliasName == "c" && imp.path == ["lib", "hinges"]);
    auto v = cast(VarDecl) p.decls[3];
    assert(v.storage == Storage.immutable_ && v.attrs[0].args[1].name == "min" && v.attrs[1].name == "preset");
    auto s = cast(StructDecl) p.decls[5];
    assert(s.fields.length == 3 && s.methods.length == 1);
    auto f = cast(FuncDecl) p.decls[7];
    assert(f.attrs[0].name == "part" && f.returnType.name == "Solid");

    // precedence: -2 ^^ 2 = -(2 ^^ 2); a - b & c = (a - b) & c
    auto u = cast(Unary) parseExpression("-2 ^^ 2", "t");
    assert(u !is null && cast(Binary) u.operand);
    auto b = cast(Binary) parseExpression("a - b & c", "t");
    assert(b.op == Tok.amp && (cast(Binary) b.left).op == Tok.minus);
    auto m = cast(Binary) parseExpression("1 + 2 * 3", "t");
    assert(m.op == Tok.plus && (cast(Binary) m.right).op == Tok.mul);

    import std.exception : assertThrown;
    assertThrown!HcadError(parse("Solid f(h) { return h; }", "t"));
    assertThrown!HcadError(parse("auto x = 1", "t"));
    assertThrown!HcadError(parse("enum x = 1;", "t"));   // constants are immutable
}
