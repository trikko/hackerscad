#!/bin/sh
# Regenerates the documentation for AI agents in docs/ from the hscad binary,
# so it always matches the language: AGENTS.md, SKILL.md (AGENTS.md with the
# front matter of a skill), llms.txt (overview), llms-full.txt (the whole
# reference), the cheatsheet, and docs/cup.png from the cup in the README.
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
# the cup of the README, from its own code: checked, and drawn as docs/cup.png
awk '/^## A model/{f=1} f&&/^```d/{g=1;next} g&&/^```/{exit} g' README.md > build/readme-cup.hcad
bin/hscad check build/readme-cup.hcad >/dev/null
bin/hscad render build/readme-cup.hcad -o docs/cup.png >/dev/null
echo "docs/ updated"
