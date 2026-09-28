# frozen_string_literal: true

# nokogiri-pure: a pure-Ruby build of Nokogiri. The gem is deliberately *named* "nokogiri" (same
# version as the upstream release it tracks) so that it can be dropped into a Gemfile with
# `path:` or `git:` and satisfy every gem that depends on nokogiri, without compiling anything.
require_relative "lib/nokogiri/version/constant"

Gem::Specification.new do |spec|
  spec.name = "nokogiri"
  spec.version = Nokogiri::VERSION
  spec.summary = "Nokogiri, implemented in pure Ruby (no C extension, no libxml2)"
  spec.description = <<~DESC
    A drop-in, pure-Ruby implementation of Nokogiri #{Nokogiri::VERSION}. The Ruby layer is
    upstream Nokogiri; the C extension, libxml2, libxslt and gumbo are replaced by Ruby ports.
  DESC
  spec.authors = ["Largo", "Mike Dalessio", "Aaron Patterson", "Yoko Harada", "Akinori MUSHA", "John Shahid", "Karol Bucek", "Sam Ruby", "Craig Barnes", "Stephen Checkoway", "Lars Kanis", "Sergio Arbeo", "Timothy Elliott", "Nobuyoshi Nakada"]
  spec.license = "MIT"
  spec.homepage = "https://github.com/Largo/nokogiri-pure"
  spec.required_ruby_version = ">= 3.2"
  spec.platform = Gem::Platform::RUBY
  spec.files = Dir["lib/**/*.rb", "LICENSE*", "README.md", "docs/**/*.md"]
  spec.require_paths = ["lib"]
  spec.bindir = "bin"
  spec.executables = []
  spec.add_runtime_dependency("racc", "~> 1.4")
end
