# frozen_string_literal: true

# Port of libxslt 1.1.43 xsltInternals.h (+ constants from xslt.h, xsltutils.h, namespaces.h,
# extra.h): the in-memory structures of compiled stylesheets and transformation contexts.
#
# Naming: struct `xsltFoo` -> class `Pure::XSLT::Foo`; field `fooBar` -> `foo_bar`.
# Strings are UTF-8 Ruby Strings; libxslt's dictionary-interned pointer comparisons are
# replaced by string equality (all names live in one dictionary per stylesheet anyway).

module Nokogiri
  module Pure
    module XSLT
      NAMESPACE = "http://www.w3.org/1999/XSL/Transform"
      DEFAULT_VERSION = "1.0"
      DEFAULT_VENDOR = "libxslt"
      DEFAULT_URL = "http://xmlsoft.org/XSLT/"
      LIBXSLT_NAMESPACE = "http://xmlsoft.org/XSLT/namespace"
      SAXON_NAMESPACE = "http://icl.com/saxon"
      XT_NAMESPACE = "http://www.jclark.com/xt"
      XALAN_NAMESPACE = "org.apache.xalan.xslt.extensions.Redirect"

      # XML_PARSE_NOENT | XML_PARSE_DTDLOAD | XML_PARSE_DTDATTR | XML_PARSE_NOCDATA
      PARSE_OPTIONS = (1 << 1) | (1 << 2) | (1 << 3) | (1 << 14)

      MAX_SORT = 15
      PAT_NO_PRIORITY = -12_345_789.0
      MAX_DEPTH = 3000
      MAX_VARS = 15_000

      # the "UNDEFINED_DEFAULT_NS" marker of namespaces.h ((const xmlChar *) -1L)
      UNDEFINED_DEFAULT_NS = Object.new.freeze
      # xsltExtMarker (preproc.c)
      EXT_MARKER = "Extension Element"

      # xsltStyleType
      FUNC_COPY = 1
      FUNC_SORT = 2
      FUNC_TEXT = 3
      FUNC_ELEMENT = 4
      FUNC_ATTRIBUTE = 5
      FUNC_COMMENT = 6
      FUNC_PI = 7
      FUNC_COPYOF = 8
      FUNC_VALUEOF = 9
      FUNC_NUMBER = 10
      FUNC_APPLYIMPORTS = 11
      FUNC_CALLTEMPLATE = 12
      FUNC_APPLYTEMPLATES = 13
      FUNC_CHOOSE = 14
      FUNC_IF = 15
      FUNC_FOREACH = 16
      FUNC_DOCUMENT = 17
      FUNC_WITHPARAM = 18
      FUNC_PARAM = 19
      FUNC_VARIABLE = 20
      FUNC_WHEN = 21
      FUNC_EXTENSION = 22

      # xsltOutputType
      OUTPUT_XML = 0
      OUTPUT_HTML = 1
      OUTPUT_TEXT = 2

      # xsltTransformState
      STATE_OK = 0
      STATE_ERROR = 1
      STATE_STOPPED = 2

      # RVT flags (stored in doc.compression by libxslt)
      RVT_LOCAL = 1
      RVT_FUNC_RESULT = 2
      RVT_GLOBAL = 3

      SOURCE_NODE_HAS_KEY = 1
      SOURCE_NODE_HAS_ID = 2

      # xsltTemplate
      class Template
        attr_accessor :next, :style, :match, :priority, :name, :name_uri, :mode, :mode_uri,
          :content, :elem, :inherited_ns, :position

        def initialize
          @priority = PAT_NO_PRIORITY
          @inherited_ns = nil
          @position = 0
        end

        def inherited_ns_nr = @inherited_ns ? @inherited_ns.length : 0
      end

      # xsltDecimalFormat
      class DecimalFormat
        attr_accessor :next, :name, :digit, :pattern_separator, :minus_sign, :infinity, :no_number,
          :decimal_point, :grouping, :percent, :permille, :zero_digit, :ns_uri

        def initialize(ns_uri, name)
          @next = nil
          @ns_uri = ns_uri
          @name = name
          @digit = +"#"
          @pattern_separator = +";"
          @decimal_point = +"."
          @grouping = +","
          @percent = +"%"
          @permille = +"‰"
          @zero_digit = +"0"
          @minus_sign = +"-"
          @infinity = +"Infinity"
          @no_number = +"NaN"
        end
      end

      # xsltDocument
      class Document
        attr_accessor :next, :main, :doc, :keys, :includes, :preproc, :nb_keys_computed

        def initialize(doc)
          @doc = doc
          @main = false
          @keys = nil
          @includes = nil
          @preproc = false
          @nb_keys_computed = 0
        end
      end

      # xsltKeyDef
      class KeyDef
        attr_accessor :next, :inst, :name, :name_uri, :match, :use, :comp, :usecomp, :ns_list
      end

      # xsltKeyTable
      class KeyTable
        attr_accessor :next, :name, :name_uri, :keys, :members

        def initialize(name, name_uri)
          @name = name
          @name_uri = name_uri
          @keys = {}
          @members = {}
        end
      end

      # xsltNumberData
      class NumberData
        attr_accessor :level, :count, :from, :value, :format, :has_format, :digits_per_group,
          :grouping_character, :grouping_character_len, :doc, :node, :count_pat, :from_pat

        def initialize
          @has_format = false
          @digits_per_group = 0
          @grouping_character = 0
          @grouping_character_len = 0
        end
      end

      # xsltElemPreComp: the common part of all precomputed instructions. +func+ is a callable
      # taking (ctxt, node, inst, comp).
      class ElemPreComp
        attr_accessor :next, :type, :func, :inst, :free

        def initialize(type = FUNC_EXTENSION)
          @type = type
        end
      end

      # xsltStylePreComp
      class StylePreComp < ElemPreComp
        attr_accessor :stype, :has_stype, :number, :order, :has_order, :descending, :lang,
          :has_lang, :case_order, :lower_first, :use, :has_use, :noescape, :name, :has_name,
          :ns, :has_ns, :mode, :mode_uri, :test, :templ, :select, :ver11, :filename,
          :has_filename, :numdata, :comp, :ns_list

        def initialize(type)
          super
          @has_stype = @has_order = @has_lang = @has_use = @has_name = @has_ns = false
          @has_filename = false
          @number = false
          @descending = false
          @lower_first = false
          @noescape = false
          @ver11 = false
          @numdata = NumberData.new
        end
      end

      # xsltStackElem
      class StackElem
        attr_accessor :next, :comp, :computed, :name, :name_uri, :select, :tree, :value,
          :fragment, :level, :context, :flags

        def initialize(context = nil)
          @context = context
          @computed = false
          @level = 0
          @flags = 0
        end
      end

      # xsltStylesheet
      class Stylesheet
        attr_accessor :parent, :next, :imports, :doc_list, :doc, :strip_spaces, :strip_all,
          :cdata_section, :variables, :templates, :templates_hash, :root_match, :key_match,
          :elem_match, :attr_match, :parent_match, :text_match, :pi_match, :comment_match,
          :ns_aliases, :attribute_sets, :ns_hash, :ns_defs, :keys, :method, :method_uri,
          :version, :encoding, :omit_xml_declaration, :decimal_format, :standalone,
          :doctype_public, :doctype_system, :indent, :media_type, :pre_comps, :warnings, :errors,
          :excl_prefix, :excl_prefix_tab, :_private, :ext_infos, :extras_nr, :includes,
          :default_alias, :nopreproc, :internalized, :literal_result, :principal,
          :forwards_compatible, :named_templates, :xpath_ctxt, :op_limit, :op_count

        def initialize(parent = nil)
          @parent = parent
          @omit_xml_declaration = -1
          @standalone = -1
          @decimal_format = DecimalFormat.new(nil, nil)
          @indent = -1
          @errors = 0
          @warnings = 0
          @excl_prefix_tab = []
          @ext_infos = nil
          @extras_nr = 0
          @internalized = true
          @literal_result = false
          @forwards_compatible = false
          @strip_all = 0
          @nopreproc = false
          @op_limit = 0
          @op_count = 0
          if parent.nil?
            @principal = self
            @xpath_ctxt = XPath::Context.new(nil)
          else
            @principal = parent.principal
          end
        end

        def excl_prefix_nr = @excl_prefix_tab.length
      end

      # xsltTransformContext
      class TransformContext
        attr_accessor :style, :type, :templ, :templ_tab, :vars, :vars_tab, :vars_base,
          :ext_functions, :ext_elements, :ext_infos, :mode, :mode_uri, :doc_list, :document,
          :node, :node_list, :output, :insert, :xpath_ctxt, :state, :global_vars, :inst,
          :xinclude, :output_file, :_private, :extras, :style_list, :sec, :error, :errctx,
          :sortfunc, :tmp_rvt, :persist_rvt, :ctxtflags, :lasttext, :debug_status,
          :parser_options, :internalized, :nb_keys, :has_templ_key_patterns,
          :current_template_rule, :initial_context_node, :initial_context_doc,
          :context_variable, :local_rvt, :key_init_level, :depth, :max_template_depth,
          :max_template_vars, :op_limit, :op_count, :source_doc_dirty, :current_id,
          :new_locale, :free_locale, :gen_sort_key,
          # pure-Ruby replacements for data libxslt squeezes into the source nodes
          :source_flags, :source_ids, :pattern_cache, :rvt_docs, :stack_overflow_reported

        def templ_nr = @templ_tab.length
        def vars_nr = @vars_tab.length
      end

      # xsltAttrVT (attrvt.c): +segments+ alternates strings and compiled expressions,
      # starting with a string iff +strstart+.
      class AttrVT
        attr_accessor :next, :strstart, :ns_list, :segments

        def initialize
          @strstart = false
          @segments = []
          @ns_list = nil
        end

        def nb_seg = @segments.length
      end

      # a result tree fragment root (XSLT_MARK_RES_TREE_FRAG)
      RES_TREE_FRAG_NAME = " fake node libxslt"

      module_function

      # XSLT_IS_RES_TREE_FRAG
      def res_tree_frag?(n)
        !n.nil? && n.type == DOCUMENT_NODE && !n.name.nil? && n.name.start_with?(" ")
      end

      # IS_XSLT_ELEM
      def xslt_elem?(n)
        !n.nil? && n.type == ELEMENT_NODE && !n.ns.nil? && n.ns.href == NAMESPACE
      end

      # IS_XSLT_REAL_NODE
      REAL_NODE_TYPES = [ELEMENT_NODE, TEXT_NODE, CDATA_SECTION_NODE, ATTRIBUTE_NODE, DOCUMENT_NODE,
                         HTML_DOCUMENT_NODE, COMMENT_NODE, PI_NODE].freeze

      def real_node?(n)
        !n.nil? && REAL_NODE_TYPES.include?(n.type)
      end

      # xsltIsBlank
      def blank?(str)
        return true if str.nil?

        str.each_byte { |b| return false unless b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D }
        true
      end

      def blank_node?(n)
        n.type == TEXT_NODE && blank?(n.content)
      end

      # xsltNextImport
      def next_import(cur)
        return nil if cur.nil?
        return cur.imports if cur.imports
        return cur.next if cur.next

        loop do
          cur = cur.parent
          return nil if cur.nil?
          return cur.next if cur.next
        end
      end

      # XSLT_GET_IMPORT_PTR
      def get_import_ptr(style, field)
        st = style
        while st
          v = st.__send__(field)
          return v unless v.nil?

          st = next_import(st)
        end
        nil
      end

      # XSLT_GET_IMPORT_INT
      def get_import_int(style, field)
        st = style
        while st
          v = st.__send__(field)
          return v if v != -1

          st = next_import(st)
        end
        -1
      end
    end
  end
end
