# frozen_string_literal: true

# Entry point for the W3C XML Schema implementation (port of libxml2 2.13.9 xmlschemas.c,
# xmlschemastypes.c, pattern.c and xmlregexp.c).
require_relative "../xmlregexp"
require_relative "structs"
require_relative "common"
require_relative "macros"
Dir[File.join(__dir__, "*.rb")].sort.each do |f|
  next if File.basename(f) == "load.rb"

  require f
end
