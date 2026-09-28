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

RubyGems can't host a second gem named `nokogiri`, hence the two names. Don't install the native
`nokogiri` gem next to `nokogiri-pure` outside Bundler: both provide `nokogiri.rb`.

Versions: `nokogiri-pure` 1.19.4.N implements Nokogiri 1.19.4 (`Nokogiri::VERSION`); N is this
project's own revision (`Nokogiri::Pure::VERSION`).

Without Bundler or gems, put `lib/` on the load path: `ruby -I path/to/nokogiri-pure/lib -rnokogiri`.

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
