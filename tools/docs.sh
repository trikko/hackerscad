#!/bin/sh
# Regenerates the documentation for AI agents in docs/ from the hcad binary,
# so it always matches the language: AGENTS.md, SKILL.md (AGENTS.md with the
# front matter of a skill), llms.txt (overview), llms-full.txt (the whole
# reference), the cheatsheet and the pictures of the tutorial's steps
# (docs/tutorial); it also checks the cup in the README.
# docs/LANGUAGE.md and docs/TUTORIAL.md are written by hand.
# Usage: tools/docs.sh
set -e
cd "$(dirname "$0")/.."
dub build -q
bin/hcad docs --agents > docs/AGENTS.md
bin/hcad docs --skill > docs/SKILL.md
bin/hcad docs --summary > docs/llms.txt
bin/hcad docs > docs/llms-full.txt
bin/hcad docs --cheatsheet > docs/CHEATSHEET.md
bin/hcad docs --cheatsheet-html > docs/cheatsheet.html
cp data/logo/it.andreafontana.hackerscad.gui.svg docs/logo.svg
# the cup of the README, from its own code: it must check (docs/cup.png is a
# screenshot of the application, taken by hand)
awk '/^## A model/{f=1} f&&/^```d/{g=1;next} g&&/^```/{exit} g' README.md > build/readme-cup.hcad
bin/hcad check build/readme-cup.hcad >/dev/null
# the language tour in the reference is the one of the Examples menu
awk '/^## A tour of the language/{f=1} f&&/^```d/{g=1;next} g&&/^```/{exit} g' docs/LANGUAGE.md > build/tour.hcad
cmp -s build/tour.hcad examples/05_language.hcad || { echo "the tour in docs/LANGUAGE.md differs from examples/05_language.hcad"; exit 1; }
# the same cup is in the Examples menu: the two must not drift apart
cmp -s build/readme-cup.hcad examples/01_cup.hcad || { echo "examples/01_cup.hcad differs from the README's cup"; exit 1; }
# and the tutorial's finished planter, but for the first line (the menu's entry)
tail -n +2 examples/02_planter.hcad | cmp -s - docs/tutorial/planter-11.hcad \
    || { echo "examples/02_planter.hcad differs from docs/tutorial/planter-11.hcad"; exit 1; }
# the tutorial's planter: the model at the end of each page must check; the
# pictures of the index from page 9's (the finished planter, before the agent
# of page 11 writes a name on it), whole and with the pot lifted out
# (the window's pictures: dub run --single tools/tutorial-shots.d)
for f in docs/tutorial/planter-*.hcad; do
    bin/hcad check "$f" >/dev/null
done
# the models of page 13, complete in its text, are its 13-*.hcad files (the
# hook as it starts; 13-hook.hcad is where the page ends): they must check
# and be the same
for f in docs/tutorial/13-*.hcad; do
    bin/hcad check "$f" >/dev/null
done
rm -rf build/page13 && mkdir -p build/page13
awk '/^```d$/{n++; f=sprintf("build/page13/%02d.hcad", n); getline; if ($0 !~ /^module /) {f=""; next}} /^```$/{f=""; next} f{print > f}' \
    docs/tutorial/13-going-further.md
for f in build/page13/*.hcad; do
    found=
    for m in docs/tutorial/13-*.hcad; do cmp -s "$f" "$m" && found=1; done
    [ -n "$found" ] || { echo "a model of page 13 differs from its docs/tutorial/13-*.hcad: $f"; exit 1; }
done
# the Carlo of page 12 checks too (a unittest keeps it the same as lib/carlo.hcad)
bin/hcad check docs/tutorial/12-carlo.hcad >/dev/null
bin/hcad render docs/tutorial/planter-09.hcad -o docs/tutorial/img/planter.png >/dev/null
sed 's/^    return p;$/    return p.move(z: 72.mm);/' docs/tutorial/planter-09.hcad > build/planter-apart.hcad
bin/hcad render build/planter-apart.hcad -o docs/tutorial/img/planter-apart.png >/dev/null
echo "docs/ updated"
