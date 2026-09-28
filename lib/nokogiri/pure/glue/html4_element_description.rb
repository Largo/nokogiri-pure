# frozen_string_literal: true

# Port of ext/nokogiri/html4_element_description.c

require_relative "../html_parser/tables"

module Nokogiri
  module HTML4
    class ElementDescription
      class << self

        # Get ElementDescription for +tag_name+
        def [](tag_name)
          desc = Nokogiri::Pure::HTMLParser.tag_lookup(tag_name.to_str)
          return nil if desc.nil?

          obj = Class.instance_method(:allocate).bind_call(self)
          obj.instance_variable_set(:@__native, desc)
          obj
        end
      end

      # A list of required attributes for this element
      def required_attributes
        d = __desc
        list = []
        return list if d.attrs_req.nil?

        # sic: libxml2's glue iterates over attrs_depr's length (a Nokogiri bug preserved here);
        # with attrs_depr NULL the C code would crash, we return what we have.
        return list if d.attrs_depr.nil?

        d.attrs_depr.length.times { |i| list << (d.attrs_req[i]&.dup) }
        list
      end

      # A list of deprecated attributes for this element
      def deprecated_attributes
        d = __desc
        return [] if d.attrs_depr.nil?

        d.attrs_depr.map(&:dup)
      end

      # A list of optional attributes for this element
      def optional_attributes
        d = __desc
        return [] if d.attrs_opt.nil?

        d.attrs_opt.map(&:dup)
      end

      # The default sub element for this element
      def default_sub_element
        d = __desc
        d.defaultsubelt&.dup
      end

      # A list of allowed sub elements for this element.
      def sub_elements
        d = __desc
        return [] if d.subelts.nil?

        d.subelts.map(&:dup)
      end

      # The description for this element
      def description
        __desc.desc.dup
      end

      # Is this element an inline element?
      def inline?
        __desc.isinline != 0
      end

      # Is this element deprecated?
      def deprecated?
        __desc.depr != 0
      end

      # Is this an empty element?
      def empty?
        __desc.empty != 0
      end

      # Should the end tag be saved?
      def save_end_tag?
        __desc.save_end_tag != 0
      end

      # Can the end tag be implied for this tag?
      def implied_end_tag?
        __desc.end_tag != 0
      end

      # Can the start tag be implied for this tag?
      def implied_start_tag?
        __desc.start_tag != 0
      end

      # Get the tag name for this ElementDescription
      def name
        n = __desc.name
        n&.dup
      end

      private

      def __desc
        d = @__native
        raise TypeError, "wrong argument type #{self.class} (expected htmlElemDesc)" if d.nil?

        d
      end
    end
  end
end
