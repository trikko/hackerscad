#!/usr/bin/env dub
/+ dub.sdl:
    name "site"
    dependency "commonmark-d" version="~>1.0.10"
    dflags "-I$PACKAGE_DIR/repo/source" "-i=hackerscad.lang"
+/
/// hackerscad.com: the home page and the reference as written in pages/, and
/// the other pages made from the docs of hackerscad's main branch, checked out
/// in repo/, so the site says what the docs say. Code is coloured by
/// hackerscad's own lexer.
///
///     dub run --single build.d -- OUT_DIR
module build;

import std.algorithm : canFind, endsWith, filter, map, sort, startsWith;
import std.array : array, join, replace, split;
import std.conv : to;
import std.file : copy, dirEntries, exists, isDir, mkdirRecurse, readText, rmdirRecurse, SpanMode, write;
import std.format : format;
import std.path : baseName, buildNormalizedPath, buildPath, dirName, stripExtension;
import std.regex : ctRegex, matchFirst, regex, replaceAll, matchAll;
import std.stdio : writeln;
import std.string : indexOf, strip, toLower;
import std.uni : isAlphaNum;

import commonmarkd : convertMarkdownToHTML, MarkdownFlag;
import hackerscad.lang.lexer : lex, Tok, Token, unitNames;

enum github = "https://github.com/trikko/hackerscad/blob/main/";
enum ghIcon = `<svg viewBox="0 0 16 16" width="22" height="22" aria-hidden="true"><path fill="currentColor" d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"/></svg>`;

immutable string[2][] nav = [["Tutorial", "/tutorial/"], ["Guides", "/guides/"], ["Reference", "/reference.html"],
    ["Cheatsheet", "/cheatsheet.html"], ["For agents", "/agents.html"], ["Download", "/download.html"]];

string here;          /// this file's folder
string repo;          /// main's checkout
string outDir;
string[string] pages; /// the docs that become pages: repository path → site path
bool[string] pictures; /// the docs' pictures the pages show, copied at the end

// ---------------------------------------------------------------- code colours

immutable bool[string] types;
shared static this()
{
    bool[string] t;
    foreach (n; ["Solid", "Profile", "Length", "Angle", "Area", "Volume", "Vec", "Vec2", "Vec3", "Plane", "Frame",
            "Path", "Surface", "Sketch", "Axis", "int", "double", "bool", "string", "void"])
        t[n] = true;
    types = cast(immutable) t;
}

string esc(const(char)[] s) => s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").idup;

/// hcad code as html, coloured by hackerscad's lexer: keywords, types, strings, numbers with their
/// units, annotations; what lies between the tokens (spaces, comments) as it is, comments coloured.
/// Code the lexer refuses (a fragment with `…` in it) is left plain.
string highlight(string code)
{
    Token[] toks;
    try
        toks = lex(code, "code");
    catch (Exception)
        return esc(code);
    // a token's place in bytes, from its line and column (columns count characters)
    size_t[] lineStart = [0];
    foreach (i, c; code)
        if (c == '\n')
            lineStart ~= i + 1;
    size_t offset(uint line, uint col)
    {
        size_t i = lineStart[line - 1];
        foreach (_; 1 .. col)
        {
            i++;
            while (i < code.length && (code[i] & 0xC0) == 0x80)
                i++;
        }
        return i;
    }
    size_t past(size_t from, uint chars)
    {
        size_t i = from;
        foreach (_; 0 .. chars)
        {
            i++;
            while (i < code.length && (code[i] & 0xC0) == 0x80)
                i++;
        }
        return i;
    }
    string gap(string s)
    {
        // comments in the space between tokens
        string r;
        size_t i;
        while (i < s.length)
        {
            if (s[i .. $].startsWith("//"))
            {
                auto e = s.indexOf('\n', i);
                auto end = e < 0 ? s.length : cast(size_t) e;
                r ~= `<span class="c">` ~ esc(s[i .. end]) ~ "</span>";
                i = end;
            }
            else if (s[i .. $].startsWith("/*") || s[i .. $].startsWith("/+"))
            {
                auto close = s[i + 1] == '*' ? "*/" : "+/";
                auto e = s.indexOf(close, i + 2);
                auto end = e < 0 ? s.length : cast(size_t) e + 2;
                r ~= `<span class="c">` ~ esc(s[i .. end]) ~ "</span>";
                i = end;
            }
            else
                r ~= esc(s[i .. i + 1]), i++;
        }
        return r;
    }
    string r;
    size_t at;
    Tok before = Tok.eof;
    foreach (k, t; toks)
    {
        if (t.kind == Tok.eof)
            break;
        auto from = offset(t.span.line, t.span.col), to = past(from, t.span.length);
        r ~= gap(code[at .. from]);
        auto text = code[from .. to];
        string cls;
        switch (t.kind)
        {
        case Tok.stringLit, Tok.interpLit:
            cls = "s";
            break;
        case Tok.intLit, Tok.floatLit:
            cls = "n";
            break;
        case Tok.ident:
            if (before == Tok.at)
                cls = "k";
            else if (text in types)
                cls = "t";
            else if (before == Tok.dot && k >= 2 && (toks[k - 2].kind == Tok.intLit || toks[k - 2].kind == Tok.floatLit)
                    && unitNames.canFind(text))
                cls = "n";
            break;
        case Tok.dot:
            // the dot of 60.mm is the number's
            if ((before == Tok.intLit || before == Tok.floatLit) && toks.length > k + 1
                    && toks[k + 1].kind == Tok.ident && unitNames.canFind(toks[k + 1].text))
                cls = "n";
            break;
        case Tok.at:
            cls = toks.length > k + 1 && toks[k + 1].kind == Tok.ident ? "k" : null;
            break;
        default:
            if (t.kind.to!string.startsWith("kw"))
                cls = "k";
        }
        r ~= cls ? `<span class="` ~ cls ~ `">` ~ esc(text) ~ "</span>" : esc(text);
        at = to;
        before = t.kind;
    }
    return r ~ gap(code[at .. $]);
}

/// html entities back to the characters they stand for (code as the lexer wants it).
string unescapeHtml(string s) =>
    s.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", `"`).replace("&#39;", "'").replace("&amp;", "&");

string colourBlocks(string body)
{
    // the blocks of hcad code coloured; every block styled as code
    auto d = regex(`<pre><code class="language-(?:d|hcad)">([\s\S]*?)</code></pre>`);
    body = body.replaceAll!(m => `<pre class="code"><code>` ~ highlight(unescapeHtml(m[1])) ~ "</code></pre>")(d);
    return body.replace("<pre><code", `<pre class="code"><code`);
}

// ---------------------------------------------------------------- titles and their ids

/// The id GitHub gives a heading: lower case, letters, digits, spaces made dashes, the rest left out.
string slug(string text)
{
    string r;
    foreach (dchar c; text.toLower)
        if (c == ' ')
            r ~= '-';
        else if (c == '-' || c == '_' || isAlphaNum(c))
            r ~= c;
    return r;
}

string stripTags(string s) => s.replaceAll(regex(`<[^>]+>`), "");

string headingIds(string body)
{
    int[string] seen;
    return body.replaceAll!((m) {
        auto s = slug(stripTags(m[2]).unescapeHtml);
        if (auto n = s in seen)
            s ~= "-" ~ (*n)++.to!string;
        else
            seen[s] = 1;
        return format(`<h%s id="%s">%s</h%s>`, m[1], s, m[2], m[1]);
    })(regex(`<h([1-6])>([\s\S]*?)</h[1-6]>`));
}

// ---------------------------------------------------------------- links

/// Where a link or picture of a doc in srcDir (a repository folder) goes on the site.
string siteLink(string srcDir, string target)
{
    if (target.matchFirst(ctRegex!`^(https?:|mailto:|#|/)`))
        return target;
    auto hash = target.indexOf('#');
    auto path = hash < 0 ? target : target[0 .. hash];
    auto anchor = hash < 0 ? "" : target[hash .. $];
    if (path.length == 0)
        return anchor;
    auto full = buildNormalizedPath(srcDir, path);
    // the README's sections: the two that are pages here go there, the rest to GitHub
    if (full == "README.md" && anchor.length)
    {
        if (anchor.startsWith("#using-hackerscad-with-an-ai-agent") || anchor.startsWith("#the-easy-way")
                || anchor.startsWith("#by-hand"))
            return "/agents.html" ~ (anchor.startsWith("#using") ? "" : anchor);
        if (anchor == "#quickstart")
            return "/download.html";
        return "https://github.com/trikko/hackerscad" ~ anchor;
    }
    if (auto p = full in pages)
        return *p ~ anchor;
    if (full.matchFirst(ctRegex!`\.(png|jpg|jpeg|svg|gif)$`) && full.startsWith("docs/"))
    {
        pictures[full] = true;
        return "/" ~ full["docs/".length .. $];
    }
    return github ~ full ~ anchor;
}

string fixLinks(string body, string srcDir) =>
    body.replaceAll!(m => format(`%s="%s"`, m[1], siteLink(srcDir, m[2].unescapeHtml)))(regex(`(href|src)="([^"]+)"`));

// ---------------------------------------------------------------- the frame

string page(string title, string body, string active = "", string side = "")
{
    string links;
    foreach (n; nav)
        links ~= format(`<a href="%s"%s>%s</a>`, n[1], n[0] == active ? ` class="on"` : "", n[0]);
    auto main = side.length ? format(`<div class="doc">%s<article class="prose">%s</article></div>`, side, body)
        : format(`<article class="prose solo">%s</article>`, body);
    return format(`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>%s · hackerscad</title>
<link href="https://fonts.googleapis.com/css2?family=Fredoka:wght@500;600&family=Inter:wght@400;500;600&family=JetBrains+Mono:wght@400;500;700&display=swap" rel="stylesheet">
<style>%s</style>
</head>
<body>
<div class="wrap">
  <nav class="top">
    <a class="brand" href="/"><img src="/logo.svg" alt="">hackerscad</a>
    <input type="checkbox" id="menu" hidden>
    <div class="links">%s</div>
    <a class="gh" href="https://github.com/trikko/hackerscad" aria-label="hackerscad on GitHub" title="GitHub">%s</a>
    <label for="menu" class="burger">menu</label>
  </nav>
  %s
  <footer><img src="/logo.svg" alt=""><span>hackerscad.com</span><a href="https://github.com/trikko/hackerscad">GitHub</a><a href="https://www.printables.com/model/345684">Carlo on Printables</a><a href="%sLICENSE">License</a></footer>
</div>
</body>
</html>
`, esc(title), readText(buildPath(here, "pages", "site.css")), links, ghIcon, main, github);
}

/// A doc's markdown as html for the site, and its title.
string convert(string src, string text, out string title)
{
    auto m = text.matchFirst(regex(`^#\s+(.*)$`, "m"));
    title = m ? stripTags(m[1]).replace("`", "").strip : src;
    auto body = convertMarkdownToHTML(text, MarkdownFlag.dialectGitHub);
    body = headingIds(colourBlocks(body));
    return fixLinks(body, dirName(src));
}

string convert(string src, out string title) => convert(src, readText(buildPath(repo, src)), title);

void put(string sitePath, string content)
{
    auto rel = sitePath.startsWith("/") ? sitePath[1 .. $] : sitePath;
    if (rel == "" || rel.endsWith("/"))
        rel ~= "index.html";
    auto path = buildPath(outDir, rel);
    mkdirRecurse(dirName(path));
    write(path, content);
}

void copyTree(string from, string to)
{
    mkdirRecurse(to);
    foreach (e; dirEntries(from, SpanMode.breadth))
    {
        auto rel = e.name[from.length + 1 .. $];
        if (e.isDir)
            mkdirRecurse(buildPath(to, rel));
        else
        {
            mkdirRecurse(dirName(buildPath(to, rel)));
            copy(e.name, buildPath(to, rel));
        }
    }
}

/// A section of the README, from its heading to the next of the same level.
string readmeSection(string heading)
{
    auto text = readText(buildPath(repo, "README.md"));
    auto level = heading[0 .. heading.indexOf(' ')];
    auto start = text.indexOf(heading ~ "\n");
    auto rest = text[start + heading.length .. $];
    auto m = rest.matchFirst(regex("^" ~ level ~ " [^#]", "m"));
    return m ? text[start .. start + heading.length + m.pre.length] : text[start .. $];
}

enum copyScript = `<script>
document.querySelectorAll('.copy').forEach(b => b.addEventListener('click', () => {
  navigator.clipboard.writeText(b.parentElement.querySelector('.text').innerText.trim());
  b.textContent = 'copied'; setTimeout(() => b.textContent = 'copy', 1500);
}));
</script>`;

// ---------------------------------------------------------------- the pages

void main(string[] args)
{
    here = dirName(__FILE_FULL_PATH__);
    repo = buildPath(here, "repo");
    outDir = args.length > 1 ? args[1] : buildPath(here, "out");
    assert(exists(buildPath(repo, "docs", "GUIDES.md")), "repo/ must be a checkout of hackerscad's main branch");

    pages = ["README.md": "/", "docs/TUTORIAL.md": "/tutorial/", "docs/GUIDES.md": "/guides/",
        "docs/LANGUAGE.md": "/reference.html", "docs/CHEATSHEET.md": "/cheatsheet.html"];
    foreach (dir, prefix; ["docs/tutorial": "/tutorial/", "docs/guides": "/guides/"])
        foreach (e; dirEntries(buildPath(repo, dir), "*.md", SpanMode.shallow))
            pages[dir ~ "/" ~ baseName(e.name)] = prefix ~ baseName(e.name).stripExtension ~ ".html";

    if (exists(outDir))
        rmdirRecurse(outDir);
    mkdirRecurse(outDir);

    // pictures: the docs' own, the logo, the home page's
    foreach (d; ["tutorial/img", "guides/img"])
        copyTree(buildPath(repo, "docs", d), buildPath(outDir, d));
    copy(buildPath(repo, "docs", "logo.svg"), buildPath(outDir, "logo.svg"));
    copyTree(buildPath(here, "img"), buildPath(outDir, "img"));

    // the home page, as written
    put("/", readText(buildPath(here, "pages", "index.html")));

    string title;
    // tutorial
    foreach (src, dst; pages)
        if (src.startsWith("docs/tutorial/") || src == "docs/TUTORIAL.md")
        {
            auto body = convert(src, title);
            put(dst, page(title, body, "Tutorial"));
        }

    // guides, each with the list of them beside it, in the order of the index
    string[string] titles;
    foreach (src, dst; pages)
        if (src.startsWith("docs/guides/"))
        {
            convert(src, title);
            titles[dst] = title;
        }
    string[] listed;
    foreach (m; readText(buildPath(repo, "docs/GUIDES.md")).matchAll(regex(`\]\(guides/([\w-]+)\.md\)`)))
    {
        auto u = "/guides/" ~ m[1] ~ ".html";
        if (u in titles && !listed.canFind(u))
            listed ~= u;
    }
    string side(string current)
    {
        string items;
        foreach (u; listed)
            items ~= format(`<a href="%s"%s>%s</a>`, u, u == current ? ` class="on"` : "", esc(titles[u]));
        return `<aside class="side"><a class="up" href="/guides/">All guides</a>` ~ items ~ "</aside>";
    }
    auto guidesBody = convert("docs/GUIDES.md", title);
    put("/guides/", page(title, guidesBody, "Guides"));
    foreach (src, dst; pages)
        if (src.startsWith("docs/guides/"))
        {
            auto body = convert(src, title);
            put(dst, page(title, body, "Guides", side(dst)));
        }

    // the reference, written for people, its sections listed beside it; the cheatsheet
    auto refBody = convert("docs/reference.md", readText(buildPath(here, "pages", "reference.md")), title);
    string toc;
    foreach (m; refBody.matchAll(regex(`<h2 id="([^"]+)">([\s\S]*?)</h2>`)))
        toc ~= format(`<a href="#%s">%s</a>`, m[1], m[2]);
    put("/reference.html", page("Language reference", refBody,
        "Reference", `<aside class="side"><a class="up" href="#">On this page</a>` ~ toc ~ "</aside>"));
    auto cheat = convert("docs/CHEATSHEET.md", title);
    put("/cheatsheet.html", page("Cheatsheet", cheat, "Cheatsheet"));

    // agents: the README's section, its prompt with a copy button
    auto agentsText = readmeSection("## Using hackerscad with an AI agent")
        .replace("## Using hackerscad with an AI agent", "# Using hackerscad with an AI agent");
    auto agents = convert("README.md", agentsText, title);
    agents = agents.replaceAll!(m => `<div class="prompt"><div class="text">` ~ stripTags(m[1]).strip
        ~ `</div><button class="copy" type="button">copy</button></div>`)(
        regex(`<blockquote>\s*<p>(Install the hackerscad skill[\s\S]*?)</p>\s*</blockquote>`));
    put("/agents.html", page(title, agents ~ copyScript, "For agents"));

    // download: the README's quickstart with a button per system, and how to build it
    auto dlText = readmeSection("## Quickstart").replace("## Quickstart", "# Download")
        ~ readText(buildPath(here, "pages", "build-it-yourself.md"));
    auto dl = convert("README.md", dlText, title);
    dl = dl.replace("</h1>", "</h1>" ~ readText(buildPath(here, "pages", "download-buttons.html")));
    put("/download.html", page(title, dl, "Download"));

    // every picture a page shows that is not there yet (one beside a doc, not in its img folder)
    foreach (p; pictures.keys)
    {
        auto dst = buildPath(outDir, p["docs/".length .. $]);
        if (!exists(dst))
        {
            mkdirRecurse(dirName(dst));
            copy(buildPath(repo, p), dst);
        }
    }
    writeln("site written to ", outDir);
}
