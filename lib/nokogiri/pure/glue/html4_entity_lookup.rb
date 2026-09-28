# frozen_string_literal: true

# Port of ext/nokogiri/html4_entity_lookup.c

require_relative "../html_parser/tables"

module Nokogiri
  module HTML4
    class EntityLookup
      # Get the HTML4::EntityDescription for +key+
      def get(key)
        desc = Nokogiri::Pure::HTMLParser.entity_lookup(key.to_str)
        return nil if desc.nil?

        Nokogiri::HTML4.const_get(:EntityDescription, false).new(desc.value, desc.name.dup, desc.desc.dup)
      end
    end
  end
end
