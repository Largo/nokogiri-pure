#!/usr/bin/env bash
# ruby.wasm checks: the smoke test, and unmodified nokogiri-dependent gems whose output must match
# what they produce on native Nokogiri. Needs node + `npm ci` in this directory.
set -euo pipefail
cd "$(dirname "$0")"
racc=$(ruby -e 'print Gem::Specification.find_by_name("racc").full_gem_path')/lib
node run.mjs smoke.rb racc="$racc"

gems=$(mktemp -d)
(cd "$gems" && for g in loofah:2.25.2 crass:1.0.7 rails-html-sanitizer:1.7.1; do
  gem fetch "${g%%:*}" -v "${g##*:}" >/dev/null && gem unpack "${g%%:*}-${g##*:}.gem" >/dev/null
done)
node run.mjs gems_demo.rb racc="$racc" loofah="$gems/loofah-2.25.2/lib" crass="$gems/crass-1.0.7/lib" \
  rhs="$gems/rails-html-sanitizer-1.7.1/lib" > "$gems/out.txt"
diff -u gems_demo.expected "$gems/out.txt" && echo "gems demo: output identical to native nokogiri"
