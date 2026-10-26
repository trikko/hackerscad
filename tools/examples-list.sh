#!/bin/sh
# Lists the models of the Examples menu, examples/NN_name.hcad in the order
# of their numbers, in gen/examples.txt: hackerscad.examples imports
# them all from it. The file is rewritten only when the list changes, so
# that it does not rebuild the program each time. Run by dub before a build.
set -e
cd "$(dirname "$0")/.."
mkdir -p gen
(cd examples && LC_ALL=C ls [0-9][0-9]_*.hcad) > gen/examples.txt.new
if cmp -s gen/examples.txt.new gen/examples.txt; then
    rm gen/examples.txt.new
else
    mv gen/examples.txt.new gen/examples.txt
fi
