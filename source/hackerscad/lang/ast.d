module hackerscad.lang.ast;

import hackerscad.lang.errors : Span;
import hackerscad.lang.lexer : Tok;

/// `Length`, `Solid[]`, `Length[string]`; null means `auto`.
final class TypeRef
{
    string name;
    TypeRef elem;   /// for arrays and AAs: the element type
    TypeRef key;    /// for AAs
    Span span;

    bool isArray() const => elem !is null && key is null;
    bool isAA() const => key !is null;

    override string toString() const
    {
        if (isAA) return elem.toString ~ "[" ~ key.toString ~ "]";
        if (isArray) return elem.toString ~ "[]";
        return name;
    }
}

struct Attribute
{
    string name;
    Arg[] args;
    Span span;
}

struct Param
{
    TypeRef type;   /// null: untyped (lambdas)
    string name;
    Expr defaultValue;
    Span span;
}

struct Arg
{
    string name;    /// null for positional
    Expr value;
    Span span;
}

// ---------------------------------------------------------------- expressions

abstract class Expr
{
    Span span;
}

final class Literal : Expr
{
    enum Type { int_, float_, string_, true_, false_, null_ }
    Type type;
    string text;
}

/// `a $(x) b`: parts.length == exprs.length + 1
final class InterpString : Expr
{
    string[] parts;
    Expr[] exprs;
}

final class Ident : Expr
{
    string name;
}

final class Dollar : Expr
{
}

final class Unary : Expr
{
    Tok op;
    Expr operand;
}

final class Binary : Expr
{
    Tok op;
    Expr left, right;
}

final class Assign : Expr
{
    Tok op;   /// Tok.assign or a compound assignment
    Expr target, value;
}

final class IncDec : Expr
{
    bool increment, prefix;
    Expr target;
}

final class Ternary : Expr
{
    Expr cond, then, otherwise;
}

final class Call : Expr
{
    Expr callee;
    Arg[] args;
    Expr[] templateArgs;   /// f!(…)
    bool hasParens = true; /// false for `f!(x)` used without a call
}

final class Member : Expr
{
    Expr object;
    string name;
    Span nameSpan;
}

final class Index : Expr
{
    Expr object;
    Expr[] indices;
}

final class Slice : Expr
{
    Expr object;
    Expr lo, hi;   /// both null for a[]
}

final class ArrayLit : Expr
{
    Expr[] elems;
}

final class AssocLit : Expr
{
    Expr[] keys, values;
}

final class Lambda : Expr
{
    Param[] params;
    Expr exprBody;
    Block blockBody;
}

// ---------------------------------------------------------------- statements

abstract class Stmt
{
    Span span;
}

final class ExprStmt : Stmt
{
    Expr expr;
}

final class Block : Stmt
{
    Stmt[] stmts;
    bool scoped = true;   /// false for `int a, b;` declaration groups
    uint endLine;         /// the line of its closing brace (0 when it has none)
}

enum Storage
{
    auto_,      /// auto or explicit type: mutable
    immutable_,
    const_,
}

final class VarDecl : Stmt
{
    Attribute[] attrs;
    Storage storage;
    TypeRef type;
    string name;
    Span nameSpan;
    Expr init;
    bool isPrivate;
}

final class FuncDecl : Stmt
{
    Attribute[] attrs;
    TypeRef returnType;   /// null for auto
    string name;
    Span nameSpan;
    Param[] params;
    Block body;
    Expr exprBody;
    bool isPrivate;
}

final class StructDecl : Stmt
{
    string name;
    VarDecl[] fields;
    FuncDecl[] methods;
    bool isPrivate;
}

final class If : Stmt
{
    Expr cond;
    Stmt then, otherwise;
}

final class Foreach : Stmt
{
    Param key;     /// optional index variable
    Param value;
    Expr aggregate;
    Expr hi;       /// non-null for foreach (i; lo .. hi)
    bool reverse;
    Stmt body;
}

final class For : Stmt
{
    Stmt init;
    Expr cond, step;
    Stmt body;
}

final class While : Stmt
{
    Expr cond;
    Stmt body;
}

final class Return : Stmt
{
    Expr value;
}

final class Break : Stmt
{
}

final class Continue : Stmt
{
}

final class AssertStmt : Stmt
{
    Expr cond, message;
}

final class Switch : Stmt
{
    Expr subject;
    Expr[][] caseValues;  /// empty entry = default
    Stmt[][] caseBodies;
}

final class ImportDecl : Stmt
{
    string[] path;        /// std.shapes → ["std", "shapes"]
    string aliasName;     /// import c = lib.hinges;
    string[] selective;   /// import hardware : M3, M4;
    bool isPublic;        /// public import: who imports this module sees them too
}

final class Unittest : Stmt
{
    Block body;
}

final class ModuleDecl : Stmt
{
    Attribute[] attrs;
    string[] name;
}

final class Program
{
    string file;
    ModuleDecl moduleDecl;
    Stmt[] decls;
}
