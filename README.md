# hackerscad.com

This branch is the website, apart from the program: it does not come from `main` and is never merged into it. The site is made from two places:

- this branch: the home page, the language reference written for people, the style, and the home page's pictures with the models they are rendered from;
- `main`: the tutorial, the guides, the cheatsheet and the README, turned into pages as they are, so the site always says what the docs say.

## Build it

With a D compiler and dub, and a checkout of `main` in `repo/` (a link to one is enough):

```sh
ln -s /path/to/hackerscad repo
dub run --single build.d -- out      # the site, in out/
```

`build.d` turns the docs' Markdown into pages with [commonmark-d](https://code.dlang.org/packages/commonmark-d) (GitHub's dialect), colours the code with hackerscad's own lexer (`repo/source/hackerscad/lang/lexer.d`), and makes the links between docs links between pages. Every page gets a description, its address and the picture of `static/og.png` for the previews of shared links; the site also gets `sitemap.xml`, `robots.txt`, `llms.txt` (its pages, for language models) and `llms-full.txt` (main's docs for agents).

To look at it: any static file server on `out/`, for example `websitino out --index`.

## What is where

| | |
|---|---|
| `build.d` | the generator |
| `pages/index.html` | the home page, written by hand |
| `pages/reference.md` | the language reference for people (`docs/LANGUAGE.md` in `main` is the one for agents) |
| `pages/site.css` | the style of the generated pages |
| `pages/privacy.md` | the privacy page, in English and Italian: update it when the site starts collecting or loading something new |
| `pages/build-it-yourself.md`, `pages/download-buttons.html` | the parts of the download page that are not in the README |
| `img/` | the home page's pictures and the 3D viewer's STL files |
| `static/` | copied to the top of the site: the favicons, the web manifest, the picture of shared links (`og.png`), the fonts (`fonts/`, instead of Google Fonts) and three.js for the 3D viewer (`js/three/`, instead of a CDN), so that nothing is loaded from elsewhere |
| `models/` | the models the pictures are rendered from, `og.html` (the picture of shared links), and `images.sh`, which renders them again |

## The pictures

```sh
models/images.sh          # the renders and the STL files, with hcad
models/images.sh --shot   # also the screenshot of the application (needs hackerscad and mutter)
models/images.sh --og     # only static/og.png, from models/og.html (needs Chrome)
```

## Publishing

The workflow that builds the site and publishes it with GitHub Pages is `site.yml`, in `main` (a workflow started by hand must live in the default branch). It runs when the docs change in `main`, by hand (Actions › site › Run workflow), and after every push to this branch, whose `.github/workflows/pages.yml` starts it.

Once, in the repository's settings:

- **Pages:** source "GitHub Actions", custom domain `hackerscad.com`, "Enforce HTTPS".
- At the domain's provider: `A` records for `hackerscad.com` to GitHub Pages (185.199.108.153, 185.199.109.153, 185.199.110.153, 185.199.111.153) and a `CNAME` record for `www` to `trikko.github.io`.
