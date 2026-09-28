# frozen_string_literal: true

# Pure-Ruby port of libxslt 1.1.43 (+ libexslt): see lib/nokogiri/pure/xslt/*.rb.

require_relative "xslt/internals"
require_relative "xslt/utils"
require_relative "xslt/stylesheet"
require_relative "xslt/preproc"
require_relative "xslt/templates"
require_relative "xslt/attributes"
require_relative "xslt/pattern"
require_relative "xslt/keys"
require_relative "xslt/variables"
require_relative "xslt/transform"
require_relative "xslt/functions"
require_relative "xslt/extensions"
require_relative "xslt/numbers"

Nokogiri::Pure::XSLT.register_all_extras
if File.exist?(File.join(__dir__, "xslt", "exslt.rb"))
  require_relative "xslt/exslt"
  Nokogiri::Pure::XSLT::EXSLT.register_all if Nokogiri::Pure::XSLT::EXSLT.respond_to?(:register_all)
end
