#!/bin/sh
# run_crtcheck.sh - check the Ruby runtime's printf, strtod and sscanf against the system glibc:
# tools/crt/test/mkfmt.c writes about 1.4 million reference cases from glibc, test/crtcheck.rb replays them
# through swmm5/crt.rb and counts the differences. The vectors go to a temporary folder and are deleted.
set -e
cd "$(dirname "$0")/.."
T=$(mktemp -d "${TMPDIR:-/tmp}/rbcrt.XXXXXX")
gcc -O2 -o "$T/mkfmt" ../tools/crt/test/mkfmt.c -lm
"$T/mkfmt" > "$T/fmt.txt"
ruby --disable-gems test/crtcheck.rb "$T/fmt.txt"
rm -rf "$T"
