# nokogiri-pure

A drop-in, **pure-Ruby** implementation of [Nokogiri](https://nokogiri.org) 1.19.4 that needs no
compiled C extension, no libxml2, no libxslt and no gumbo.

The public Ruby API *is* upstream Nokogiri (its `lib/` is included verbatim). Only the native layer
is replaced: the C glue in `ext/nokogiri/*.c` and the C libraries under it are ported to Ruby,
following libxml2 2.13.9 / libxslt 1.1.43 / gumbo closely enough that output, error messages
and edge-case behaviour match the native gem.

> Status: every native method of Nokogiri's C extension is implemented, and upstream Nokogiri's own
> test suite (≈6700 tests) passes except for a test of C memory accounting. Each component is
> also checked differentially against the native gem (see `test-pure/`). Performance work is ongoing.
> See `docs/ARCHITECTURE.md` for how it's built.

## Installing

There are two gemspecs, providing the same code:

| gem | where | use it when |
|---|---|---|
| `nokogiri-pure` | rubygems.org | you `require "nokogiri"` yourself and nothing else depends on the `nokogiri` gem |
| `nokogiri` (`nokogiri.gemspec`) | this git repo | other gems in your bundle depend on `nokogiri` (loofah, rails-html-sanitizer, …) and must use this implementation |

```ruby
# Gemfile — replace native Nokogiri everywhere, including as other gems' dependency:
gem "nokogiri", git: "https://github.com/Largo/nokogiri-pure"
# (or with a local checkout)
gem "nokogiri", path: "../nokogiri-pure"

# Gemfile — just use it directly:
gem "nokogiri-pure"
```

Either way, `require "nokogiri"` loads it. `require "nokogiri/pure"` (the gem name's path, which
`Bundler.require` uses for `gem "nokogiri-pure"`) does the same.

RubyGems can't host a second gem named `nokogiri`, hence the two names. Don't install the native
`nokogiri` gem next to `nokogiri-pure` outside Bundler: both provide `nokogiri.rb`.

Versions: `nokogiri-pure` 1.19.4.N implements Nokogiri 1.19.4 (`Nokogiri::VERSION`); N is this
project's own revision (`Nokogiri::Pure::VERSION`).

Without Bundler or gems, put `lib/` on the load path: `ruby -I path/to/nokogiri-pure/lib -rnokogiri`.

## ruby.wasm

nokogiri-pure runs on [ruby.wasm](https://github.com/ruby/ruby.wasm), in the browser or in Node, so
gems that depend on Nokogiri work there unmodified. CI runs the `wasm/` checks: a smoke test of every
component (XML/HTML4/HTML5 parsing, XPath/CSS, SAX, Reader, XSLT, XSD, RelaxNG, C14N), and
loofah + rails-html-sanitizer producing byte-identical output to native Nokogiri.

**With `rbwasm` (packs Ruby and your bundle into one `.wasm`):** point the Gemfile's `nokogiri` at
this implementation, so every gem depending on `nokogiri` uses it:

```ruby
# Gemfile
gem "nokogiri", git: "https://github.com/Largo/nokogiri-pure"
gem "loofah"          # or any other gem that depends on nokogiri
gem "ruby_wasm", group: :development
```

```bash
bundle exec rbwasm build --ruby-version 3.4 -o app.wasm
```

The result is a WASI program with the bundle packed inside; in it, `require "/bundle/setup"` and
then `require "loofah"` (or `"nokogiri"`) as usual. Verified: a Ruby 3.4 `app.wasm` built this way
runs Loofah's sanitizers on nokogiri-pure under Node's WASI. The first `rbwasm build` compiles Ruby
for wasm32-wasi (≈20 minutes, cached afterwards).

**With `@ruby/wasm-wasi` and your own file loading:** put nokogiri-pure's `lib/` (and `racc`'s
`lib/`) on the load path in the VM's filesystem, then `require "nokogiri"`. `wasm/run.mjs` is a
minimal Node example using `@bjorn3/browser_wasi_shim`, the same WASI layer browsers use:

```bash
cd wasm && npm ci
node run.mjs your_script.rb racc=$(ruby -e 'print Gem::Specification.find_by_name("racc").full_gem_path')/lib
```

Notes:
- The JS engine's native stack is small, and ruby.wasm spends it on compiling code and on blocks
  yielded from C methods. nokogiri-pure loads its code on a fresh Fiber (which ruby.wasm starts on a
  shallow stack), keeps its files' ASTs shallow (CI-enforced), and avoids recursing through C
  iterators, so deeply nested documents work (tested to 1000 levels for XSLT, 250 for parsing,
  serialising, XPath/CSS, `traverse`). Recursion in *your* code through `each`/blocks is limited to a
  few dozen levels on wasm, e.g. a Builder block nested ~60 deep.
- Loading everything takes ~2 s in ruby.wasm (Node 20).
- When mounting gem directories yourself, leave out compiled extensions (`*.so`): ruby.wasm cannot
  load them, and e.g. racc only falls back to pure Ruby if `racc/cparse.so` is absent.

## Why

Nokogiri's native gem is fast but needs a compiler (or a precompiled binary for your exact
platform). This implementation runs anywhere Ruby runs: unusual platforms, WebAssembly
(ruby.wasm), sandboxes, and single-file packagers.

It is much slower than native Nokogiri; use it where portability matters more than raw speed.

## Releasing

Bump `Nokogiri::Pure::VERSION` (lib/nokogiri/pure/version.rb), commit, and push a tag
`v<version>`. `.github/workflows/release.yml` runs the test suite, publishes `nokogiri-pure` to
rubygems.org (Trusted Publishing — see the one-time setup notes at the top of the workflow) and
creates a GitHub release with both `.gem` files attached.

## Testing

```bash
bin/test                            # upstream Nokogiri's test suite, run against lib/
bin/test test/xml/test_node.rb      # a single upstream test file
```

`bin/test` expects the upstream Nokogiri v1.19.4 checkout (with its `test/html5lib-tests`
submodule) at `../nokogiri-upstream`, or wherever `NOKOGIRI_UPSTREAM` points.

Correctness is also checked differentially against the native gem (see `test-pure/`).

## License

MIT, like Nokogiri (see `LICENSE-nokogiri.md`). The ported libraries are MIT-licensed as well
(libxml2, libxslt: MIT; gumbo: Apache-2.0, see the upstream `LICENSE-DEPENDENCIES.md`).
