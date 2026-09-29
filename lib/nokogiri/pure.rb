# frozen_string_literal: true

# Entry point matching the gem name (nokogiri-pure -> `require "nokogiri/pure"`, which is also what
# Bundler.require tries): loads all of Nokogiri, same as `require "nokogiri"`. The pure-Ruby
# replacement for the C extension itself is nokogiri/pure/init.rb.
require_relative "../nokogiri"
