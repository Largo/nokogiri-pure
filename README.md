# nokogiri-pure

A drop-in, **pure-Ruby** implementation of [Nokogiri](https://nokogiri.org) 1.19.4 that needs no
compiled C extension, no libxml2, no libxslt and no gumbo.

The public Ruby API *is* upstream Nokogiri (its `lib/` is included verbatim). Only the native layer
is replaced: the C glue in `ext/nokogiri/*.c` and the C libraries under it are ported to Ruby,
following libxml2 2.13.9 / libxslt 1.1.43 / gumbo closely enough that output, error messages
and edge-case behaviour match the native gem.

> Status: work in progress. See `docs/ARCHITECTURE.md` for how it's built, and run
> `ruby -Ilib -rnokogiri -e 'puts Nokogiri::Pure.unimplemented'` for the native methods that are
> still stubbed out.

## Using it

The gemspec is named `nokogiri` (version = the upstream release it tracks), so a Gemfile entry
replaces the native gem everywhere, including for gems that depend on nokogiri:

```ruby
gem "nokogiri", git: "https://github.com/Largo/nokogiri-pure"
# or, with a local checkout:
gem "nokogiri", path: "../nokogiri-pure"
```

Without Bundler, put `lib/` on the load path: `ruby -I path/to/nokogiri-pure/lib -rnokogiri ...`.

## Why

Nokogiri's native gem is fast but needs a compiler (or a precompiled binary for your exact
platform). This implementation runs anywhere Ruby runs: unusual platforms, WebAssembly
(ruby.wasm), sandboxes, and single-file packagers.

It is much slower than native Nokogiri; use it where portability matters more than raw speed.

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
