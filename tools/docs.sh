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
# the tutorial's planter: the model at the end of each page must check; the
# pictures of the index from page 9's (the finished planter, before the agent
# of page 11 writes a name on it), whole and with the pot lifted out
# (the window's pictures: dub run --single tools/tutorial-shots.d)
for f in docs/tutorial/planter-*.hcad; do
    bin/hcad check "$f" >/dev/null
done
bin/hcad render docs/tutorial/planter-09.hcad -o docs/tutorial/img/planter.png >/dev/null
sed 's/^    return p;$/    return p.move(z: 72.mm);/' docs/tutorial/planter-09.hcad > build/planter-apart.hcad
bin/hcad render build/planter-apart.hcad -o docs/tutorial/img/planter-apart.png >/dev/null
echo "docs/ updated"
