# frozen_string_literal: true

# Entry point matching the gem name (nokogiri-pure -> `require "nokogiri/pure"`, which is also what
# Bundler.require tries): loads all of Nokogiri, same as `require "nokogiri"`. The pure-Ruby
# replacement for the C extension itself is nokogiri/pure/init.rb.

# The native gem is already loaded (Nokogiri without our internals): keep it. Loading the Ruby layer
# a second time, from this gem's copy, fails with "superclass mismatch" and leaves Nokogiri broken.
if defined?(::Nokogiri::XML::Document) && !defined?(::Nokogiri::Pure::Tree)
  warn("nokogiri-pure: native Nokogiri #{::Nokogiri::VERSION} is already loaded; using it instead", uplevel: 1)
  return
end

require_relative "../nokogiri"
