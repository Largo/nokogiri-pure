# frozen_string_literal: true

# nokogiri-pure: instead of loading the C (or Java) extension, load the pure-Ruby implementation
# of the same classes and methods.
require_relative "pure"

if Nokogiri::Pure::WASM
  # ruby.wasm may not have RubyGems loaded; upstream's version/info.rb needs Gem::Version and
  # Gem::Platform.
  unless defined?(::Gem::Platform) && defined?(::Gem::Version)
    begin
      require "rubygems"
    rescue LoadError
      %w[rubygems/version rubygems/platform].each do |f|
        require f
      rescue LoadError
        nil
      end
    end
  end

  # Pre-load the rest of nokogiri.rb's requires, in its order, on a shallow native stack (see
  # Nokogiri::Pure.load_shallow). nokogiri.rb's own require_relative calls then find them loaded.
  # (This file is still being loaded by the outer fiber, and version/info.rb requires it; mark it
  # as provided so the inner fiber doesn't wait on the outer fiber's require lock.)
  $LOADED_FEATURES << File.expand_path(__FILE__) unless $LOADED_FEATURES.include?(File.expand_path(__FILE__))
  Nokogiri::Pure.load_shallow do
    %w[version class_resolver syntax_error xml xslt html4 html decorators/slop css html4/builder
      encoding_handler html5].each { |f| require_relative f }
    require_relative "pure/wasm_overrides"
  end
end
