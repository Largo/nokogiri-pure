# nokogiri-pure architecture

Goal: a drop-in, pure-Ruby Nokogiri (API-compatible with Nokogiri 1.19.4 on CRuby, i.e. matching
its libxml2 2.13.9 / libxslt 1.1.43 / gumbo behaviour) that needs no compiled C extension.

## Layout

- `lib/nokogiri.rb`, `lib/nokogiri/**` — upstream Nokogiri v1.19.4 Ruby code, kept verbatim
  except `lib/nokogiri/extension.rb`, which loads `nokogiri/pure` instead of the C extension.
- `lib/nokogiri/pure.rb` — defines the class/module skeleton (same as `Init_nokogiri()` in
  ext/nokogiri/nokogiri.c), the LIBXML_* constants, then loads everything below.
- `lib/nokogiri/pure/*.rb` — pure-Ruby ports of the *libraries*:
  - `tree.rb`     libxml2 tree.c/entities.c/(parts of valid.c): structs + `Pure::Tree.*` functions
  - `errors.rb`   xmlError, structured error handler emulation (`Pure::Errors`)
  - `wrap.rb`     wrapper <-> struct plumbing (`Pure.wrap_node`, `Pure.unwrap`, ...)
  - `util.rb`     UTF-8 helpers, URI resolution
  - `save.rb`     xmlsave.c + HTMLtree.c serialisation
  - `parser.rb`   XML parser (parser.c + SAX2.c)
  - `xpath*.rb`   XPath 1.0 (xpath.c)
  - `gumbo/`      HTML5 parser (port of gumbo-parser)
  - `html_parser.rb` libxml2 HTMLparser.c (HTML4)
  - ... c14n, xinclude, valid (DTD validation), schemas, relaxng, xslt, reader
- `lib/nokogiri/pure/glue/*.rb` — ports of the C *glue* (`ext/nokogiri/*.c`): they define the
  native methods on `Nokogiri::XML::Node` etc. One file per C file (or group of tiny files).

## Conventions

- libxml2 struct `xmlFoo` -> `Nokogiri::Pure::XmlFoo` (XmlNode, XmlAttr, XmlDoc, XmlNs, XmlDtd,
  XmlEntity, XmlElementDecl, XmlAttributeDecl, XmlElementContent). Field names are snake_case
  versions of libxml2's (`nsDef` -> `ns_def`, `ExternalID` -> `external_id`, ...).
- libxml2 function `xmlFooBar()` -> `Pure::Tree.foo_bar()` (or `Pure::<Module>.foo_bar`).
- Node type constants: `Pure::ELEMENT_NODE` etc. (same numbers as libxml2).
- Strings in structs are UTF-8 Ruby Strings. Element/attr names are interned (`-name`).
- A Ruby wrapper object (e.g. `Nokogiri::XML::Element`) holds its struct in ivar `@__native`;
  the struct points back via `_private` (documents: `XmlDoc#_ruby_doc`).
  Always create wrappers with `Pure.wrap_node(struct)` / `Pure.wrap_document(klass, doc)` /
  `Pure.wrap_namespace(ns, doc)` / `Pure.wrap_node_set(array_of_structs, rb_doc)`.
- Errors: code that would call libxml2's structured error handler creates a `Pure::XmlError`
  and calls `Pure::Errors.report(err)`. Glue collects them with `Pure::Errors.collecting(list) { }`.
  Messages must match libxml2 byte-for-byte (including the trailing "\n").
- "freeing" a C node is simply dropping references; never mutate a node that a wrapper might
  still reference in ways libxml2 wouldn't.

## Reference sources (read-only)

- /root/workspace/nokogiri-upstream        upstream nokogiri v1.19.4 (ext/, gumbo-parser/, test/)
- /root/workspace/nokogiri-pure-ref/libxml2-2.13.9, libxslt-1.1.43
- The installed native gem (`gem "nokogiri", "1.19.4"`) is the behavioural oracle:
  `ruby -e 'gem "nokogiri", "1.19.4"; require "nokogiri"; ...'` (run it outside -Ilib).

## Testing

`bin/test [test files...]` runs upstream's test suite (test/ in nokogiri-upstream) against lib/.

## Native method stubs / progress

`lib/nokogiri/pure/glue/_stubs.rb` (generated from ext/nokogiri/*.c) defines a NotImplementedError
stub for each of the 205 native methods; it loads first, and real implementations in the other
glue files override them. `ruby -Ilib -rnokogiri -e 'p Nokogiri::Pure::STUBS.count { |t, m, _| t.instance_method(m).source_location&.first&.end_with?("_stubs.rb") }'`
shows how many are still unimplemented.
