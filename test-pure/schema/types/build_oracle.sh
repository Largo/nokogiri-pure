#!/bin/sh
# Build the direct C oracle against a libxml2 2.13.9 build tree
#   (mkdir b && cd b && <libxml2-2.13.9>/configure --disable-shared && make libxml2.la)
# usage: build_oracle.sh <libxml2 source dir> <build dir> [out]
set -e
SRC=${1:?libxml2 source dir}
LX=${2:?libxml2 build dir}
OUT=${3:-$(dirname "$0")/types_oracle}
gcc -O1 -I"$LX/include" -I"$SRC/include" -o "$OUT" "$(dirname "$0")/types_oracle.c" "$LX/.libs/libxml2.a" -lm
