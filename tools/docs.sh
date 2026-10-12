#!/bin/sh
# Regenerates the documentation for AI agents in docs/ from the hscad binary,
# so it always matches the language: AGENTS.md, SKILL.md (AGENTS.md with the
# front matter of a skill), llms.txt (overview), llms-full.txt (the whole
# reference), the cheatsheet and the pictures of the tutorial's steps
# (docs/tutorial); it also checks the cup in the README.
# docs/LANGUAGE.md and docs/TUTORIAL.md are written by hand.
# Usage: tools/docs.sh
set -e
cd "$(dirname "$0")/.."
dub build -q
bin/hscad docs --agents > docs/AGENTS.md
bin/hscad docs --skill > docs/SKILL.md
bin/hscad docs --summary > docs/llms.txt
bin/hscad docs > docs/llms-full.txt
bin/hscad docs --cheatsheet > docs/CHEATSHEET.md
bin/hscad docs --cheatsheet-html > docs/cheatsheet.html
cp data/logo/it.andreafontana.hackerscad.gui.svg docs/logo.svg
# the cup of the README, from its own code: it must check (docs/cup.png is a
# screenshot of the application, taken by hand)
awk '/^## A model/{f=1} f&&/^```d/{g=1;next} g&&/^```/{exit} g' README.md > build/readme-cup.hcad
bin/hscad check build/readme-cup.hcad >/dev/null
# the tutorial's pot, one model and one picture per step
for f in docs/tutorial/pot-*.hcad; do
    bin/hscad check "$f" >/dev/null
    bin/hscad render "$f" -o "${f%.hcad}.png" >/dev/null
done
# the profile of step 1 also from the front, the drainage holes from above
bin/hscad render docs/tutorial/pot-1-profile.hcad -o docs/tutorial/pot-1-profile-front.png >/dev/null
bin/hscad render docs/tutorial/pot-5.hcad -o docs/tutorial/pot-5-top.png >/dev/null
echo "docs/ updated"
