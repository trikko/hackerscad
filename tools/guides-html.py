#!/usr/bin/env python3
# The topic guides (docs/guides) as one page of HTML, for reading offline or
# serving on a LAN: build/guides-site/index.html, its pictures in img/ beside it.
# Needs python-markdown and pygments. Usage: python3 tools/guides-html.py
import markdown, re, os, html

base=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
root=os.path.join(base,'docs')
idx=open(f'{root}/GUIDES.md').read()
entries=re.findall(r'^### \[(.+?)\]\(guides/(\w+)\.md\)\n\n(?:\[<img[^\n]*\n\n)?(.+)$', idx, re.M)
try:
    import pygments; ext=['tables','fenced_code','codehilite','toc']
except ImportError: ext=['tables','fenced_code','toc']
from pygments.formatters import HtmlFormatter
css_code=HtmlFormatter(style='friendly').get_style_defs('.codehilite')
secs=[]; nav=[]; heads={}
for title,slug,desc in entries:
    t=open(f'{root}/guides/{slug}.md').read()
    m0=re.search(r'img/([\w-]+\.png)',t)
    if m0:
        heads[slug]='img/'+m0.group(1)
    t=re.sub(r'<!-- render:.*?-->\n','',t)
    t=t.replace('```d\n','```d\n')
    md=markdown.Markdown(extensions=ext, extension_configs={'codehilite':{'guess_lang':False,'css_class':'codehilite'},'toc':{'slugify':lambda v,s: slug+'-'+re.sub(r'[^a-z0-9]+','-',v.lower()).strip('-')}})
    h=md.convert(t)
    # the pictures as files beside the page, loaded as they come into view
    h=re.sub(r'<img ([^>]*)src="(img/[^"]+)"',r'<img loading="lazy" \1src="\2"',h)
    h=re.sub(r'href="(\w+)\.md"',lambda m: f'href="#{m.group(1)}"',h)
    h=re.sub(r'href="\.\./(\w+)\.md"',r'href="https://github.com/trikko/hackerscad/blob/main/docs/\1.md"',h)
    h=h.replace('href="TUTORIAL.md"','href="https://github.com/trikko/hackerscad/blob/main/docs/TUTORIAL.md"')
    hd=f'<div class="head" style="background-image:url({heads[slug]})"></div>' if slug in heads else ''
    h=h.replace('</h1>','</h1>'+hd,1)
    secs.append(f'<section id="{slug}" class="guide">{h}<p class="top"><a href="#index">↑ index</a></p></section>')
    nav.append(f'<li><a href="#{slug}">{html.escape(title)}</a></li>')
cards=''.join(f'<a class="card" href="#{s}"><div class="thumb" style="background-image:url({heads.get(s,"")})"></div><b>{html.escape(t)}</b><span>{markdown.markdown(d)[3:-4]}</span></a>' for t,s,d in entries)
logo=open(os.path.join(root,'logo.svg')).read() if os.path.exists(os.path.join(root,'logo.svg')) else ''
page=f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>hackerscad — Guides</title><style>
:root{{--sky:#0FC3F2;--ink:#1d2330;--mute:#5b6475;--bg:#f6f8fb;--line:#e2e7ef}}
*{{box-sizing:border-box}} body{{margin:0;font:16px/1.6 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;color:var(--ink);background:var(--bg)}}
nav{{position:fixed;top:0;left:0;bottom:0;width:260px;overflow:auto;background:#fff;border-right:1px solid var(--line);padding:20px 16px}}
nav .brand{{display:flex;align-items:center;gap:10px;font-weight:700;font-size:18px;margin-bottom:14px}} nav .brand svg{{width:36px;height:36px}}
nav ol{{padding-left:22px;margin:0}} nav li{{margin:4px 0}} nav a{{color:var(--ink);text-decoration:none}} nav a:hover{{color:var(--sky)}}
main{{margin-left:260px;padding:32px 48px;max-width:1100px}}
header.hero h1{{font-size:40px;margin:0 0 8px}} header.hero p{{color:var(--mute);max-width:760px}}
.cards{{display:grid;grid-template-columns:repeat(auto-fill,minmax(250px,1fr));gap:14px;margin:24px 0 40px}}
.thumb{{height:150px;margin:-14px -16px 12px;border-radius:10px 10px 0 0;background:#e9edf4 center/contain no-repeat;border-bottom:1px solid var(--line)}}
.head{{height:260px;margin:4px 0 18px;border-radius:12px;background:#e9edf4 center/contain no-repeat;border:1px solid var(--line)}}
.card{{display:block;overflow:hidden;background:#fff;border:1px solid var(--line);border-radius:12px;padding:14px 16px;color:var(--ink);text-decoration:none;border-top:4px solid var(--sky);padding-top:14px}}
.card:hover{{box-shadow:0 4px 18px rgba(15,195,242,.18)}} .card b{{display:block;margin-bottom:6px}} .card span{{font-size:13.5px;color:var(--mute)}}
.guide{{background:#fff;border:1px solid var(--line);border-radius:14px;padding:28px 36px;margin:0 0 36px}}
.guide h1{{margin-top:0;font-size:30px;border-bottom:3px solid var(--sky);padding-bottom:6px}} .guide h2{{margin-top:34px;font-size:22px}} .guide h3{{font-size:18px}}
table{{border-collapse:collapse;width:100%;margin:14px 0;font-size:14.5px}} th,td{{border:1px solid var(--line);padding:6px 10px;text-align:left;vertical-align:top}}
th{{background:#eef7fb}} tr:nth-child(even) td{{background:#fafcfe}}
code{{font:13.5px/1.5 "JetBrains Mono","Fira Code",Consolas,monospace;background:#eef2f7;padding:1px 5px;border-radius:4px}}
pre{{background:#f3f6fa;border:1px solid var(--line);border-left:4px solid var(--sky);border-radius:8px;padding:12px 14px;overflow:auto}} pre code{{background:none;padding:0}}
.codehilite{{background:none}} img{{max-width:100%;border-radius:10px;border:1px solid var(--line);display:block;margin:12px auto}}
.top{{text-align:right;font-size:13px}} a{{color:#0a8fb3}}
@media (max-width:900px){{nav{{display:none}} main{{margin:0;padding:16px}} .guide{{padding:18px}}}}
{css_code}
</style></head><body>
<nav><div class="brand">{logo}<span>hackerscad guides</span></div><ol>{''.join(nav)}</ol></nav>
<main><header class="hero" id="index"><h1>Guides</h1><p>One page for each topic: what it is for and when to choose it, its variants side by side, every parameter, the usual mistakes, where it is in the application and what an AI agent asks and checks.</p></header>
<div class="cards">{cards}</div>{''.join(secs)}</main></body></html>'''
import shutil; os.makedirs(os.path.join(base,'build','guides-site'),exist_ok=True); shutil.copytree(os.path.join(root,'guides','img'),os.path.join(base,'build','guides-site','img'),dirs_exist_ok=True); open(os.path.join(base,'build','guides-site','index.html'),'w').write(page)
print(len(page)//1024,'KB')
