# frozen_string_literal: true

# relaxng.c: the datatype libraries (built-in RELAX NG library and the W3C XML Schema
# datatypes, the latter on top of the xmlschemastypes.c port in schemas/).
module Nokogiri
  module Pure
    module RelaxNG
      module_function

      def xsd
        unless defined?(@xsd_loaded) && @xsd_loaded
          require_relative "../schemas/load"
          @xsd_loaded = true
        end
        Schemas
      end

      def xsd_type(name)
        xsd::Types.get_predefined_type(name, "http://www.w3.org/2001/XMLSchema")
      end

      # xmlRelaxNGSchemaTypeHave
      def schema_type_have(_data, type)
        return -1 if type.nil?

        xsd_type(type).nil? ? 0 : 1
      end

      # xmlRelaxNGSchemaTypeCheck. Returns [ret, result]; +want+ is false when the C caller
      # passes result == NULL.
      def schema_type_check(_data, type, value, want, node)
        return [-1, nil] if type.nil? || value.nil?

        typ = xsd_type(type)
        return [-1, nil] if typ.nil?

        ret, val = xsd::Types.val_predef_type_node(typ, value, want, node)
        return [2, val] if ret == 2
        return [1, val] if ret == 0
        return [0, val] if ret > 0

        [-1, val]
      end

      FACET_TYPES = {
        "minInclusive" => :XML_SCHEMA_FACET_MININCLUSIVE,
        "minExclusive" => :XML_SCHEMA_FACET_MINEXCLUSIVE,
        "maxInclusive" => :XML_SCHEMA_FACET_MAXINCLUSIVE,
        "maxExclusive" => :XML_SCHEMA_FACET_MAXEXCLUSIVE,
        "totalDigits" => :XML_SCHEMA_FACET_TOTALDIGITS,
        "fractionDigits" => :XML_SCHEMA_FACET_FRACTIONDIGITS,
        "pattern" => :XML_SCHEMA_FACET_PATTERN,
        "enumeration" => :XML_SCHEMA_FACET_ENUMERATION,
        "whiteSpace" => :XML_SCHEMA_FACET_WHITESPACE,
        "length" => :XML_SCHEMA_FACET_LENGTH,
        "maxLength" => :XML_SCHEMA_FACET_MAXLENGTH,
        "minLength" => :XML_SCHEMA_FACET_MINLENGTH,
      }.freeze

      # xmlRelaxNGSchemaFacetCheck
      def schema_facet_check(_data, type, facetname, val, strval, value)
        return -1 if type.nil? || strval.nil?

        typ = xsd_type(type)
        return -1 if typ.nil?

        s = xsd
        facet = s.new_facet
        ft = FACET_TYPES[facetname]
        return -1 if ft.nil?

        facet.type = s.const_get(ft)
        facet.value = val
        # xmlSchemaCheckFacet reports through a fresh schema parser context without handlers,
        # i.e. xmlGenericError
        ret = with_generic_errors { s.check_facet(facet, typ, nil, type) }
        return -1 if ret != 0

        ret = s::Types.validate_facet(typ, facet, strval, value)
        return -1 if ret != 0

        0
      end

      # Errors raised with neither a structured nor a generic handler go to the global
      # structured handler when one is set, else xmlGenericError prints them on stderr.
      def with_generic_errors(&block)
        return yield if Errors.handler

        Errors.with_handler(->(err) { $stderr.write(format_error(err)) }, &block)
      end

      # xmlRelaxNGSchemaFreeValue
      def schema_free_value(_data, _value) = nil

      # xmlRelaxNGSchemaTypeCompare
      def schema_type_compare(_data, type, value1, ctxt1, comp1, value2, ctxt2)
        return -1 if type.nil? || value1.nil? || value2.nil?

        typ = xsd_type(type)
        return -1 if typ.nil?

        if comp1.nil?
          ret, res1 = xsd::Types.val_predef_type_node(typ, value1, true, ctxt1)
          return -1 if ret != 0
          return -1 if res1.nil?
        else
          res1 = comp1
        end
        ret, res2 = xsd::Types.val_predef_type_node(typ, value2, true, ctxt2)
        return -1 if ret != 0

        ret = xsd::Types.compare_values(res1, res2)
        return -1 if ret == -2
        return 1 if ret == 0

        0
      end

      # xmlRelaxNGDefaultTypeHave
      def default_type_have(_data, type)
        return -1 if type.nil?
        return 1 if type == "string"
        return 1 if type == "token"

        0
      end

      # xmlRelaxNGDefaultTypeCheck
      def default_type_check(_data, type, value, _want, _node)
        return [-1, nil] if value.nil?
        return [1, nil] if type == "string"
        return [1, nil] if type == "token"

        [0, nil]
      end

      # xmlRelaxNGDefaultTypeCompare
      def default_type_compare(_data, type, value1, _ctxt1, _comp1, value2, _ctxt2)
        ret = -1
        if type == "string"
          ret = str_equal(value1, value2) ? 1 : 0
        elsif type == "token"
          if !str_equal(value1, value2)
            nval = normalize(nil, value1)
            nvalue = normalize(nil, value2)
            ret = if nval.nil? || nvalue.nil?
              -1
            elsif nval == nvalue
              1
            else
              0
            end
          else
            ret = 1
          end
        end
        ret
      end

      # xmlStrEqual
      def str_equal(a, b)
        return true if a.nil? && b.nil?
        return false if a.nil? || b.nil?

        a.b == b.b
      end

      REGISTERED_TYPES = Hash2.new

      # xmlRelaxNGRegisterTypeLibrary
      def register_type_library(namespace, data, have, check, comp, facet, freef)
        return -1 if namespace.nil? || check.nil? || comp.nil?
        return -1 unless REGISTERED_TYPES.lookup(namespace).nil?

        lib = TypeLibrary.new(namespace.dup, data, have, check, comp, facet, freef)
        REGISTERED_TYPES.add(namespace, lib) < 0 ? -1 : 0
      end

      # xmlRelaxNGInitTypes
      def init_types
        return 0 if @type_initialized

        m = RelaxNG
        register_type_library(XSD_DATATYPES_NS, nil,
          m.method(:schema_type_have), m.method(:schema_type_check),
          m.method(:schema_type_compare), m.method(:schema_facet_check),
          m.method(:schema_free_value))
        register_type_library(XML_RELAXNG_NS, nil,
          m.method(:default_type_have), m.method(:default_type_check),
          m.method(:default_type_compare), nil, nil)
        @type_initialized = true
        0
      end
    end
  end
end
