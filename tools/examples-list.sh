#!/bin/sh
# Lists the models of the Examples menu, examples/NN_name.hcad in the order
# of their numbers, in build/gen/examples.txt: hackerscad.examples imports
# them all from it. The file is rewritten only when the list changes, so
# that it does not rebuild the program each time. Run by dub before a build.
set -e
cd "$(dirname "$0")/.."
mkdir -p build/gen
(cd examples && LC_ALL=C ls [0-9][0-9]_*.hcad) > build/gen/examples.txt.new
if cmp -s build/gen/examples.txt.new build/gen/examples.txt; then
    rm build/gen/examples.txt.new
else
    mv build/gen/examples.txt.new build/gen/examples.txt
fi
