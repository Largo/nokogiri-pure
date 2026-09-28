# frozen_string_literal: true

# Port of ext/nokogiri/xml_encoding_handler.c

module Nokogiri
  class EncodingHandler
    class << self
      undef_method :new rescue nil
      undef_method :allocate rescue nil

      def [](key)
        handler = Nokogiri::Pure::Enc.find_handler(key.to_str)
        return nil unless handler

        eh = Class.instance_method(:allocate).bind_call(self)
        eh.instance_variable_set(:@__native, handler)
        eh
      end

      def delete(name)
        Nokogiri::Pure::Enc.del_alias(name.to_str) == 0 ? true : nil
      end

      def alias(from, to)
        Nokogiri::Pure::Enc.add_alias(from.to_str, to.to_str)
        to
      end

      def clear_aliases!
        Nokogiri::Pure::Enc.clear_aliases
        self
      end
    end

    def name
      @__native.name.dup
    end
  end
end
