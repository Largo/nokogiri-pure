# frozen_string_literal: true

# The gem published to rubygems.org. RubyGems can't host a second gem named "nokogiri", so this one
# is "nokogiri-pure"; it still provides `require "nokogiri"`. To make it satisfy *other* gems'
# dependency on "nokogiri" (e.g. under ruby.wasm), use the sibling nokogiri.gemspec via Bundler's
# `gem "nokogiri", git: ...` / `path: ...` — see README.
require_relative "lib/nokogiri/version/constant"
require_relative "lib/nokogiri/pure/version"

Gem::Specification.new do |spec|
  spec.name = "nokogiri-pure"
  spec.version = Nokogiri::Pure::VERSION
  spec.summary = "Nokogiri #{Nokogiri::VERSION}, implemented in pure Ruby (no C extension, no libxml2)"
  spec.description = <<~DESC
    A pure-Ruby implementation of Nokogiri #{Nokogiri::VERSION}: the Ruby layer is upstream Nokogiri,
    and its C extension, libxml2, libxslt and gumbo are replaced by faithful Ruby ports. Runs anywhere
    Ruby runs, including ruby.wasm. Provides `require "nokogiri"`.
  DESC
  spec.authors = ["Largo", "Mike Dalessio", "Aaron Patterson", "Yoko Harada", "Akinori MUSHA", "John Shahid",
    "Karol Bucek", "Sam Ruby", "Craig Barnes", "Stephen Checkoway", "Lars Kanis", "Sergio Arbeo",
    "Timothy Elliott", "Nobuyoshi Nakada"]
  spec.license = "MIT"
  spec.homepage = "https://github.com/Largo/nokogiri-pure"
  spec.metadata = {
    "source_code_uri" => "https://github.com/Largo/nokogiri-pure",
    "rubygems_mfa_required" => "true",
  }
  spec.required_ruby_version = ">= 3.2"
  spec.platform = Gem::Platform::RUBY
  spec.files = Dir["lib/**/*.rb", "LICENSE*", "README.md", "docs/**/*.md"]
  spec.require_paths = ["lib"]
  spec.add_runtime_dependency("racc", "~> 1.4")
end
