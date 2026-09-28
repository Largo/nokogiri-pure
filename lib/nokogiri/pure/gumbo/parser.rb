# frozen_string_literal: true

# Port of gumbo-parser's parser.c (HTML5 tree construction).
#
# Only the parts of the gumbo output that Nokogiri observes are kept: node types, names,
# namespaces, attributes, text, start line numbers, the doctype, the quirks mode, errors and the
# output status. (parse_flags, end positions and original text spans of nodes are not needed.)

require_relative "constants"
require_relative "tables"
require_relative "char_ref_table"
require_relative "util"
require_relative "error"
require_relative "tokenizer"

module Nokogiri
  module Pure
    module Gumbo
      # GumboNode
      class Node
        attr_accessor :type, :parent, :index_within_parent, :children,
          :tag, :name, :tag_namespace, :attributes, :line,
          :text,
          :has_doctype, :doc_name, :public_identifier, :system_identifier, :doc_type_quirks_mode

        def initialize(type)
          @type = type
          @parent = nil
          @index_within_parent = -1
          @line = 0
        end

        def element?
          @type == NODE_ELEMENT || @type == NODE_TEMPLATE
        end

        def inspect
          case @type
          when NODE_DOCUMENT then "#<Gumbo::Node document>"
          when NODE_ELEMENT, NODE_TEMPLATE then "#<Gumbo::Node <#{@name}> ns=#{@tag_namespace}>"
          else "#<Gumbo::Node type=#{@type} #{@text.inspect}>"
          end
        end
      end

      # GumboOptions
      class Options
        attr_accessor :tab_stop, :stop_on_first_error, :max_attributes, :max_tree_depth, :max_errors,
          :fragment_context, :fragment_namespace, :fragment_encoding, :quirks_mode,
          :fragment_context_has_form_ancestor, :parse_noscript_content_as_text

        def initialize
          @tab_stop = 8
          @stop_on_first_error = false
          @max_attributes = 400
          @max_tree_depth = 400
          @max_errors = -1
          @fragment_context = nil
          @fragment_namespace = NAMESPACE_HTML
          @fragment_encoding = nil
          @quirks_mode = DOCTYPE_NO_QUIRKS
          @fragment_context_has_form_ancestor = false
          @parse_noscript_content_as_text = false
        end
      end

      # GumboOutput
      class Output
        attr_accessor :document, :root, :errors, :document_error, :status

        def initialize(document)
          @document = document
          @root = nil
          @errors = []
          @document_error = false
          @status = STATUS_OK
        end
      end

      STATUS_STRINGS = {
        STATUS_OK => "OK",
        STATUS_OUT_OF_MEMORY => "System allocator returned NULL during parsing",
        STATUS_TOO_MANY_ATTRIBUTES => "Attributes per element limit exceeded",
        STATUS_TREE_TOO_DEEP => "Document tree depth limit exceeded",
      }.freeze

      module_function

      # gumbo_status_to_string
      def status_to_string(status)
        STATUS_STRINGS.fetch(status, "Unknown GumboOutputStatus value")
      end

      # gumbo_parse_with_options. `input` is a String; it is treated as a sequence of bytes.
      def parse_with_options(options, input)
        input = input.b unless input.encoding == Encoding::BINARY
        Parser.new(options, input).run
      end

      class Parser
        HTML_BIT = 1 << NAMESPACE_HTML
        SVG_BIT = 1 << NAMESPACE_SVG
        MATHML_BIT = 1 << NAMESPACE_MATHML

        def self.tagset(html = [], svg: [], math: [])
          a = Array.new(TAG_LAST + 1, 0)
          html.each { |t| a[t] |= HTML_BIT }
          svg.each { |t| a[t] |= SVG_BIT }
          math.each { |t| a[t] |= MATHML_BIT }
          a.freeze
        end

        def self.pieces(*strs)
          strs.map { |s| s.b.freeze }.freeze
        end

        QUIRKS_MODE_PUBLIC_ID_PREFIXES = pieces(
          "+//Silmaril//dtd html Pro v0r11 19970101//",
          "-//AdvaSoft Ltd//DTD HTML 3.0 asWedit + extensions//",
          "-//AS//DTD HTML 3.0 asWedit + extensions//",
          "-//IETF//DTD HTML 2.0 Level 1//",
          "-//IETF//DTD HTML 2.0 Level 2//",
          "-//IETF//DTD HTML 2.0 Strict Level 1//",
          "-//IETF//DTD HTML 2.0 Strict Level 2//",
          "-//IETF//DTD HTML 2.0 Strict//",
          "-//IETF//DTD HTML 2.0//",
          "-//IETF//DTD HTML 2.1E//",
          "-//IETF//DTD HTML 3.0//",
          "-//IETF//DTD HTML 3.2 Final//",
          "-//IETF//DTD HTML 3.2//",
          "-//IETF//DTD HTML 3//",
          "-//IETF//DTD HTML Level 0//",
          "-//IETF//DTD HTML Level 1//",
          "-//IETF//DTD HTML Level 2//",
          "-//IETF//DTD HTML Level 3//",
          "-//IETF//DTD HTML Strict Level 0//",
          "-//IETF//DTD HTML Strict Level 1//",
          "-//IETF//DTD HTML Strict Level 2//",
          "-//IETF//DTD HTML Strict Level 3//",
          "-//IETF//DTD HTML Strict//",
          "-//IETF//DTD HTML//",
          "-//Metrius//DTD Metrius Presentational//",
          "-//Microsoft//DTD Internet Explorer 2.0 HTML Strict//",
          "-//Microsoft//DTD Internet Explorer 2.0 HTML//",
          "-//Microsoft//DTD Internet Explorer 2.0 Tables//",
          "-//Microsoft//DTD Internet Explorer 3.0 HTML Strict//",
          "-//Microsoft//DTD Internet Explorer 3.0 HTML//",
          "-//Microsoft//DTD Internet Explorer 3.0 Tables//",
          "-//Netscape Comm. Corp.//DTD HTML//",
          "-//Netscape Comm. Corp.//DTD Strict HTML//",
          "-//O'Reilly and Associates//DTD HTML 2.0//",
          "-//O'Reilly and Associates//DTD HTML Extended 1.0//",
          "-//O'Reilly and Associates//DTD HTML Extended Relaxed 1.0//",
          "-//SoftQuad Software//DTD HoTMetaL PRO 6.0::19990601::)extensions to HTML 4.0//",
          "-//SoftQuad//DTD HoTMetaL PRO 4.0::19971010::extensions to HTML 4.0//",
          "-//Spyglass//DTD HTML 2.0 Extended//",
          "-//SQ//DTD HTML 2.0 HoTMetaL + extensions//",
          "-//Sun Microsystems Corp.//DTD HotJava HTML//",
          "-//Sun Microsystems Corp.//DTD HotJava Strict HTML//",
          "-//W3C//DTD HTML 3 1995-03-24//",
          "-//W3C//DTD HTML 3.2 Draft//",
          "-//W3C//DTD HTML 3.2 Final//",
          "-//W3C//DTD HTML 3.2//",
          "-//W3C//DTD HTML 3.2S Draft//",
          "-//W3C//DTD HTML 4.0 Frameset//",
          "-//W3C//DTD HTML 4.0 Transitional//",
          "-//W3C//DTD HTML Experimental 19960712//",
          "-//W3C//DTD HTML Experimental 970421//",
          "-//W3C//DTD W3 HTML//",
          "-//W3O//DTD W3 HTML 3.0//",
          "-//WebTechs//DTD Mozilla HTML 2.0//",
          "-//WebTechs//DTD Mozilla HTML//",
        )

        QUIRKS_MODE_PUBLIC_ID_EXACT_MATCHES = pieces(
          "-//W3O//DTD W3 HTML Strict 3.0//EN//",
          "-/W3C/DTD HTML 4.0 Transitional/EN",
          "HTML",
        )

        QUIRKS_MODE_SYSTEM_ID_EXACT_MATCHES = pieces(
          "http://www.ibm.com/data/dtd/v11/ibmxhtml1-transitional.dtd",
        )

        LIMITED_QUIRKS_PUBLIC_ID_PREFIXES = pieces(
          "-//W3C//DTD XHTML 1.0 Frameset//",
          "-//W3C//DTD XHTML 1.0 Transitional//",
        )

        SYSTEM_ID_DEPENDENT_PUBLIC_ID_PREFIXES = pieces(
          "-//W3C//DTD HTML 4.01 Frameset//",
          "-//W3C//DTD HTML 4.01 Transitional//",
        )

        LEGAL_XMLNS = pieces(
          "http://www.w3.org/1999/xhtml",
          "http://www.w3.org/2000/svg",
          "http://www.w3.org/1998/Math/MathML",
        )

        # kActiveFormattingScopeMarker
        MARKER = Node.new(NODE_ELEMENT).freeze

        # the static form_ancestor used by fragment_parser_init
        FORM_ANCESTOR = Node.new(NODE_ELEMENT).tap do |n|
          n.children = [].freeze
          n.tag = TAG_FORM
          n.name = nil
          n.tag_namespace = NAMESPACE_HTML
          n.attributes = [].freeze
        end.freeze

        DEFAULT_SCOPE_HTML = [
          TAG_APPLET, TAG_CAPTION, TAG_HTML, TAG_TABLE, TAG_TD, TAG_TH, TAG_MARQUEE, TAG_OBJECT, TAG_TEMPLATE,
        ].freeze
        DEFAULT_SCOPE_MATH = [TAG_MI, TAG_MO, TAG_MN, TAG_MS, TAG_MTEXT, TAG_ANNOTATION_XML].freeze
        DEFAULT_SCOPE_SVG = [TAG_FOREIGNOBJECT, TAG_DESC, TAG_TITLE].freeze

        HEADING_TAGS = tagset([TAG_H1, TAG_H2, TAG_H3, TAG_H4, TAG_H5, TAG_H6])
        TD_TH_TAGS = tagset([TAG_TD, TAG_TH])
        DD_DT_TAGS = tagset([TAG_DD, TAG_DT])

        MATHML_INTEGRATION_POINT_TAGS = tagset(math: [TAG_MI, TAG_MO, TAG_MN, TAG_MS, TAG_MTEXT])
        HTML_INTEGRATION_POINT_SVG_TAGS = tagset(svg: [TAG_FOREIGNOBJECT, TAG_DESC, TAG_TITLE])
        FOSTER_TARGET_TAGS = tagset([TAG_TABLE, TAG_TBODY, TAG_TFOOT, TAG_THEAD, TAG_TR])
        TABLE_ROW_CONTEXT_TAGS = tagset([TAG_HTML, TAG_TR, TAG_TEMPLATE])
        TABLE_CONTEXT_TAGS = tagset([TAG_HTML, TAG_TABLE, TAG_TEMPLATE])
        TABLE_BODY_CONTEXT_TAGS = tagset([TAG_HTML, TAG_TBODY, TAG_TFOOT, TAG_THEAD, TAG_TEMPLATE])
        HTML_ONLY_TAGS = tagset([TAG_HTML])
        DEFAULT_SCOPE_TAGS = tagset(DEFAULT_SCOPE_HTML, svg: DEFAULT_SCOPE_SVG, math: DEFAULT_SCOPE_MATH)
        LIST_SCOPE_TAGS = tagset(DEFAULT_SCOPE_HTML + [TAG_OL, TAG_UL], svg: DEFAULT_SCOPE_SVG, math: DEFAULT_SCOPE_MATH)
        BUTTON_SCOPE_TAGS = tagset(DEFAULT_SCOPE_HTML + [TAG_BUTTON], svg: DEFAULT_SCOPE_SVG, math: DEFAULT_SCOPE_MATH)
        TABLE_SCOPE_TAGS = tagset([TAG_HTML, TAG_TABLE, TAG_TEMPLATE])
        SELECT_SCOPE_TAGS = tagset([TAG_OPTGROUP, TAG_OPTION])
        IMPLIED_END_TAGS = tagset([
          TAG_DD, TAG_DT, TAG_LI, TAG_OPTGROUP, TAG_OPTION, TAG_P, TAG_RB, TAG_RP, TAG_RT, TAG_RTC,
        ])
        THOROUGH_IMPLIED_END_TAGS = tagset([
          TAG_CAPTION, TAG_COLGROUP, TAG_DD, TAG_DT, TAG_LI, TAG_OPTGROUP, TAG_OPTION, TAG_P, TAG_RB,
          TAG_RP, TAG_RT, TAG_RTC, TAG_TBODY, TAG_TD, TAG_TFOOT, TAG_TH, TAG_THEAD, TAG_TR,
        ])
        NONCLOSABLE_OK_TAGS = tagset([
          TAG_DD, TAG_DT, TAG_LI, TAG_OPTGROUP, TAG_OPTION, TAG_P, TAG_RB, TAG_RP, TAG_RT, TAG_RTC,
          TAG_TBODY, TAG_TD, TAG_TFOOT, TAG_TH, TAG_THEAD, TAG_TR, TAG_BODY, TAG_HTML,
        ])
        SPECIAL_TAGS = tagset(
          [
            TAG_ADDRESS, TAG_APPLET, TAG_AREA, TAG_ARTICLE, TAG_ASIDE, TAG_BASE, TAG_BASEFONT,
            TAG_BGSOUND, TAG_BLOCKQUOTE, TAG_BODY, TAG_BR, TAG_BUTTON, TAG_CAPTION, TAG_CENTER, TAG_COL,
            TAG_COLGROUP, TAG_DD, TAG_DETAILS, TAG_DIR, TAG_DIV, TAG_DL, TAG_DT, TAG_EMBED, TAG_FIELDSET,
            TAG_FIGCAPTION, TAG_FIGURE, TAG_FOOTER, TAG_FORM, TAG_FRAME, TAG_FRAMESET, TAG_H1, TAG_H2,
            TAG_H3, TAG_H4, TAG_H5, TAG_H6, TAG_HEAD, TAG_HEADER, TAG_HGROUP, TAG_HR, TAG_HTML,
            TAG_IFRAME, TAG_IMG, TAG_INPUT, TAG_LI, TAG_LINK, TAG_LISTING, TAG_MARQUEE, TAG_MENU,
            TAG_META, TAG_NAV, TAG_NOEMBED, TAG_NOFRAMES, TAG_NOSCRIPT, TAG_OBJECT, TAG_OL, TAG_P,
            TAG_PARAM, TAG_PLAINTEXT, TAG_PRE, TAG_SCRIPT, TAG_SECTION, TAG_SELECT, TAG_STYLE,
            TAG_SUMMARY, TAG_TABLE, TAG_TBODY, TAG_TD, TAG_TEMPLATE, TAG_TEXTAREA, TAG_TFOOT, TAG_TH,
            TAG_THEAD, TAG_TR, TAG_UL, TAG_WBR, TAG_XMP, TAG_TITLE,
          ],
          math: [TAG_MI, TAG_MO, TAG_MN, TAG_MS, TAG_MTEXT, TAG_ANNOTATION_XML],
          svg: [TAG_FOREIGNOBJECT, TAG_DESC, TAG_TITLE],
        )
        ADDRESS_DIV_P_TAGS = tagset([TAG_ADDRESS, TAG_DIV, TAG_P])

        # token tag sets used by the insertion modes
        HEAD_BODY_HTML_BR = tagset([TAG_HEAD, TAG_BODY, TAG_HTML, TAG_BR])
        BODY_HTML_BR = tagset([TAG_BODY, TAG_HTML, TAG_BR])
        IN_HEAD_VOID = tagset([TAG_BASE, TAG_BASEFONT, TAG_BGSOUND, TAG_LINK])
        NOFRAMES_STYLE = tagset([TAG_NOFRAMES, TAG_STYLE])
        IN_HEAD_NOSCRIPT_HEAD_TAGS = tagset([TAG_BASEFONT, TAG_BGSOUND, TAG_LINK, TAG_META, TAG_NOFRAMES, TAG_STYLE])
        HEAD_NOSCRIPT = tagset([TAG_HEAD, TAG_NOSCRIPT])
        AFTER_HEAD_HEAD_TAGS = tagset([
          TAG_BASE, TAG_BASEFONT, TAG_BGSOUND, TAG_LINK, TAG_META, TAG_NOFRAMES, TAG_SCRIPT, TAG_STYLE,
          TAG_TEMPLATE, TAG_TITLE,
        ])
        IN_BODY_HEAD_TAGS = AFTER_HEAD_HEAD_TAGS
        IN_BODY_BLOCK_START = tagset([
          TAG_ADDRESS, TAG_ARTICLE, TAG_ASIDE, TAG_BLOCKQUOTE, TAG_CENTER, TAG_DETAILS, TAG_DIALOG,
          TAG_DIR, TAG_DIV, TAG_DL, TAG_FIELDSET, TAG_FIGCAPTION, TAG_FIGURE, TAG_FOOTER, TAG_HEADER,
          TAG_HGROUP, TAG_MAIN, TAG_MENU, TAG_NAV, TAG_OL, TAG_P, TAG_SECTION, TAG_SUMMARY, TAG_UL,
          TAG_SEARCH,
        ])
        PRE_LISTING = tagset([TAG_PRE, TAG_LISTING])
        IN_BODY_BLOCK_END = tagset([
          TAG_ADDRESS, TAG_ARTICLE, TAG_ASIDE, TAG_BLOCKQUOTE, TAG_BUTTON, TAG_CENTER, TAG_DETAILS,
          TAG_DIALOG, TAG_DIR, TAG_DIV, TAG_DL, TAG_FIELDSET, TAG_FIGCAPTION, TAG_FIGURE, TAG_FOOTER,
          TAG_HEADER, TAG_HGROUP, TAG_LISTING, TAG_MAIN, TAG_MENU, TAG_NAV, TAG_OL, TAG_PRE,
          TAG_SECTION, TAG_SUMMARY, TAG_UL, TAG_SEARCH,
        ])
        FORMATTING_START = tagset([
          TAG_B, TAG_BIG, TAG_CODE, TAG_EM, TAG_FONT, TAG_I, TAG_S, TAG_SMALL, TAG_STRIKE, TAG_STRONG,
          TAG_TT, TAG_U,
        ])
        FORMATTING_END = tagset([
          TAG_A, TAG_B, TAG_BIG, TAG_CODE, TAG_EM, TAG_FONT, TAG_I, TAG_NOBR, TAG_S, TAG_SMALL,
          TAG_STRIKE, TAG_STRONG, TAG_TT, TAG_U,
        ])
        APPLET_MARQUEE_OBJECT = tagset([TAG_APPLET, TAG_MARQUEE, TAG_OBJECT])
        IN_BODY_VOID = tagset([TAG_AREA, TAG_BR, TAG_EMBED, TAG_IMG, TAG_IMAGE, TAG_KEYGEN, TAG_WBR])
        PARAM_SOURCE_TRACK = tagset([TAG_PARAM, TAG_SOURCE, TAG_TRACK])
        OPTGROUP_OPTION = tagset([TAG_OPTGROUP, TAG_OPTION])
        RB_RTC = tagset([TAG_RB, TAG_RTC])
        RP_RT = tagset([TAG_RP, TAG_RT])
        IN_BODY_IGNORED_START = tagset([
          TAG_CAPTION, TAG_COL, TAG_COLGROUP, TAG_FRAME, TAG_HEAD, TAG_TBODY, TAG_TD, TAG_TFOOT,
          TAG_TH, TAG_THEAD, TAG_TR,
        ])
        IN_TABLE_TEXT_TARGETS = tagset([TAG_TABLE, TAG_TBODY, TAG_TEMPLATE, TAG_TFOOT, TAG_THEAD, TAG_TR])
        TBODY_TFOOT_THEAD = tagset([TAG_TBODY, TAG_TFOOT, TAG_THEAD])
        TD_TH_TR = tagset([TAG_TD, TAG_TH, TAG_TR])
        IN_TABLE_IGNORED_END = tagset([
          TAG_BODY, TAG_CAPTION, TAG_COL, TAG_COLGROUP, TAG_HTML, TAG_TBODY, TAG_TD, TAG_TFOOT, TAG_TH,
          TAG_THEAD, TAG_TR,
        ])
        STYLE_SCRIPT_TEMPLATE = tagset([TAG_STYLE, TAG_SCRIPT, TAG_TEMPLATE])
        IN_CAPTION_CLOSE_START = tagset([
          TAG_CAPTION, TAG_COL, TAG_COLGROUP, TAG_TBODY, TAG_TD, TAG_TFOOT, TAG_TH, TAG_THEAD, TAG_TR,
        ])
        IN_CAPTION_IGNORED_END = tagset([
          TAG_BODY, TAG_COL, TAG_COLGROUP, TAG_HTML, TAG_TBODY, TAG_TD, TAG_TFOOT, TAG_TH, TAG_THEAD,
          TAG_TR,
        ])
        IN_TABLE_BODY_CLOSE_START = tagset([TAG_CAPTION, TAG_COL, TAG_COLGROUP, TAG_TBODY, TAG_TFOOT, TAG_THEAD])
        IN_TABLE_BODY_IGNORED_END = tagset([
          TAG_BODY, TAG_CAPTION, TAG_COL, TAG_COLGROUP, TAG_HTML, TAG_TD, TAG_TH, TAG_TR,
        ])
        IN_ROW_CLOSE_START = tagset([TAG_CAPTION, TAG_COL, TAG_COLGROUP, TAG_TBODY, TAG_TFOOT, TAG_THEAD, TAG_TR])
        IN_ROW_IGNORED_END = tagset([TAG_BODY, TAG_CAPTION, TAG_COL, TAG_COLGROUP, TAG_HTML, TAG_TD, TAG_TH])
        IN_CELL_IGNORED_END = tagset([TAG_BODY, TAG_CAPTION, TAG_COL, TAG_COLGROUP, TAG_HTML])
        IN_CELL_CLOSE_END = tagset([TAG_TABLE, TAG_TBODY, TAG_TFOOT, TAG_THEAD, TAG_TR])
        INPUT_KEYGEN_TEXTAREA = tagset([TAG_INPUT, TAG_KEYGEN, TAG_TEXTAREA])
        SCRIPT_TEMPLATE = tagset([TAG_SCRIPT, TAG_TEMPLATE])
        SELECT_IN_TABLE_TAGS = tagset([TAG_CAPTION, TAG_TABLE, TAG_TBODY, TAG_TFOOT, TAG_THEAD, TAG_TR, TAG_TD, TAG_TH])
        IN_TEMPLATE_HEAD_TAGS = AFTER_HEAD_HEAD_TAGS
        IN_TEMPLATE_TABLE_TAGS = tagset([TAG_CAPTION, TAG_COLGROUP, TAG_TBODY, TAG_TFOOT, TAG_THEAD])
        FOREIGN_BREAKOUT_START = tagset([
          TAG_B, TAG_BIG, TAG_BLOCKQUOTE, TAG_BODY, TAG_BR, TAG_CENTER, TAG_CODE, TAG_DD, TAG_DIV,
          TAG_DL, TAG_DT, TAG_EM, TAG_EMBED, TAG_H1, TAG_H2, TAG_H3, TAG_H4, TAG_H5, TAG_H6, TAG_HEAD,
          TAG_HR, TAG_I, TAG_IMG, TAG_LI, TAG_LISTING, TAG_MENU, TAG_META, TAG_NOBR, TAG_OL, TAG_P,
          TAG_PRE, TAG_RUBY, TAG_S, TAG_SMALL, TAG_SPAN, TAG_STRONG, TAG_STRIKE, TAG_SUB, TAG_SUP,
          TAG_TABLE, TAG_TT, TAG_U, TAG_UL, TAG_VAR,
        ])
        BR_P = tagset([TAG_BR, TAG_P])
        MGLYPH_MALIGNMARK = tagset([TAG_MGLYPH, TAG_MALIGNMARK])
        HEADING_TAG_LIST = [TAG_H1, TAG_H2, TAG_H3, TAG_H4, TAG_H5, TAG_H6].freeze

        S_HTML = "html".b.freeze
        S_ENCODING = "encoding".b.freeze
        S_TEXT_HTML = "text/html".b.freeze
        S_APP_XHTML = "application/xhtml+xml".b.freeze
        S_XMLNS = "xmlns".b.freeze
        S_XMLNS_XLINK = "xmlns:xlink".b.freeze
        S_XLINK_NS = "http://www.w3.org/1999/xlink".b.freeze
        S_TYPE = "type".b.freeze
        S_HIDDEN = "hidden".b.freeze
        S_COLOR = "color".b.freeze
        S_FACE = "face".b.freeze
        S_SIZE = "size".b.freeze
        S_DEFINITIONURL = "definitionurl".b.freeze
        S_DEFINITION_URL = "definitionURL".b.freeze
        S_FOREIGN_OBJECT = "foreignObject".b.freeze
        S_ABOUT_LEGACY_COMPAT = "about:legacy-compat".b.freeze
        S_EMPTY = "".b.freeze

        attr_reader :output

        def initialize(options, input)
          @options = options
          @input = input

          # output_init
          document = Node.new(NODE_DOCUMENT)
          document.children = []
          document.has_doctype = false
          document.doc_name = nil
          document.public_identifier = nil
          document.system_identifier = nil
          document.doc_type_quirks_mode = DOCTYPE_NO_QUIRKS
          @output = Output.new(document)
          @max_errors = options.max_errors
          @max_attributes = options.max_attributes

          @tokenizer = Tokenizer.new(self, input, options.tab_stop)

          # parser_state_init
          @insertion_mode = INSERTION_MODE_INITIAL
          @original_insertion_mode = INSERTION_MODE_INITIAL
          @reprocess_current_token = false
          @frameset_ok = true
          @ignore_next_linefeed = false
          @foster_parent_insertions = false
          @text_type = NODE_WHITESPACE
          @text_buffer = String.new(encoding: Encoding::BINARY)
          @text_start_line = 0
          @table_character_tokens = []
          @open_elements = []
          @active_formatting_elements = []
          @template_insertion_modes = []
          @head_element = nil
          @form_element = nil
          @fragment_ctx = nil
          @current_token = nil
          @self_closing_flag_acknowledged = false
          @closed_body_tag = false
          @closed_html_tag = false
        end

        attr_reader :max_attributes

        def output_status=(status)
          @output.status = status
        end

        # gumbo_add_error
        def add_error
          @output.document_error = true
          max_errors = @max_errors
          errors = @output.errors
          return nil if max_errors >= 0 && errors.length >= max_errors

          error = Error.new
          errors << error
          error
        end

        # ---- helpers --------------------------------------------------------------------

        def token_has_attribute(token, name)
          !get_attribute(token.attributes, name).nil?
        end

        # gumbo_get_attribute
        def get_attribute(attributes, name)
          return nil if attributes.nil?

          attributes.each do |attr|
            return attr if Util.ascii_strcaseeq(attr.name, name)
          end
          nil
        end

        def attribute_matches(attributes, name, value)
          attr = get_attribute(attributes, name)
          attr ? Util.ascii_strcaseeq(value, attr.value) : false
        end

        def attribute_matches_case_sensitive(attributes, name, value)
          attr = get_attribute(attributes, name)
          attr ? cstr(value) == cstr(attr.value) : false
        end

        def cstr(s)
          i = s.index("\0")
          i ? s.byteslice(0, i) : s
        end

        def all_attributes_match(attr1, attr2)
          num_unmatched = attr2.length
          attr1.each do |attr|
            return false unless attribute_matches_case_sensitive(attr2, attr.name, attr.value)

            num_unmatched -= 1
          end
          num_unmatched == 0
        end

        def set_frameset_not_ok
          @frameset_ok = false
        end

        def create_node(type)
          Node.new(type)
        end

        def document_node
          @output.document
        end

        def is_fragment_parser
          !@fragment_ctx.nil?
        end

        def current_node
          @open_elements[-1]
        end

        def adjusted_current_node
          if @open_elements.length == 1 && @fragment_ctx
            return @fragment_ctx
          end

          @open_elements[-1]
        end

        def in_static_list(needle, haystack, exact_match)
          return false if needle.nil? || needle.empty?

          if exact_match
            haystack.any? { |s| s.bytesize == needle.bytesize && s.casecmp(needle) == 0 }
          else
            haystack.any? do |s|
              needle.bytesize >= s.bytesize && needle.byteslice(0, s.bytesize).casecmp(s) == 0
            end
          end
        end

        def set_insertion_mode(mode)
          @insertion_mode = mode
        end

        def push_template_insertion_mode(mode)
          @template_insertion_modes << mode
        end

        def pop_template_insertion_mode
          @template_insertion_modes.pop
        end

        def current_template_insertion_mode
          @template_insertion_modes.empty? ? INSERTION_MODE_INITIAL : @template_insertion_modes[-1]
        end

        def tag_in(token, is_start, tags)
          if is_start
            return false unless token.type == TOKEN_START_TAG
          else
            return false unless token.type == TOKEN_END_TAG
          end
          tags[token.tag] != 0
        end

        def tag_is(token, is_start, tag)
          if is_start
            token.type == TOKEN_START_TAG && token.tag == tag
          else
            token.type == TOKEN_END_TAG && token.tag == tag
          end
        end

        def start_tag_in(token, tags)
          token.type == TOKEN_START_TAG && tags[token.tag] != 0
        end

        def end_tag_in(token, tags)
          token.type == TOKEN_END_TAG && tags[token.tag] != 0
        end

        def start_tag_is(token, tag)
          token.type == TOKEN_START_TAG && token.tag == tag
        end

        def end_tag_is(token, tag)
          token.type == TOKEN_END_TAG && token.tag == tag
        end

        def node_tag_in_set(node, tags)
          t = node.type
          return false unless t == NODE_ELEMENT || t == NODE_TEMPLATE

          (tags[node.tag] & (1 << node.tag_namespace)) != 0
        end

        def node_qualified_tagname_is(node, ns, tag, name)
          element_tag = node.tag
          return false if node.tag_namespace != ns || element_tag != tag
          return true if tag != TAG_UNKNOWN

          Util.ascii_strcaseeq(node.name, name)
        end

        def node_html_tagname_is(node, tag, name)
          node_qualified_tagname_is(node, NAMESPACE_HTML, tag, name)
        end

        def node_tagname_is(node, tag, name)
          node_qualified_tagname_is(node, node.tag_namespace, tag, name)
        end

        def node_qualified_tag_is(node, ns, tag)
          node.tag == tag && node.tag_namespace == ns
        end

        def node_html_tag_is(node, tag)
          node.tag == tag && node.tag_namespace == NAMESPACE_HTML
        end

        # ---- insertion mode reset -------------------------------------------------------

        def get_appropriate_insertion_mode(index)
          open_elements = @open_elements
          node = open_elements[index]
          is_last = index == 0
          node = @fragment_ctx if is_last && is_fragment_parser

          if node.tag_namespace != NAMESPACE_HTML
            return is_last ? INSERTION_MODE_IN_BODY : INSERTION_MODE_INITIAL
          end

          case node.tag
          when TAG_SELECT
            return INSERTION_MODE_IN_SELECT if is_last

            i = index
            while i > 0
              ancestor = open_elements[i]
              return INSERTION_MODE_IN_SELECT if node_html_tag_is(ancestor, TAG_TEMPLATE)
              return INSERTION_MODE_IN_SELECT_IN_TABLE if node_html_tag_is(ancestor, TAG_TABLE)

              i -= 1
            end
            return INSERTION_MODE_IN_SELECT
          when TAG_TD, TAG_TH
            return INSERTION_MODE_IN_CELL unless is_last
          when TAG_TR
            return INSERTION_MODE_IN_ROW
          when TAG_TBODY, TAG_THEAD, TAG_TFOOT
            return INSERTION_MODE_IN_TABLE_BODY
          when TAG_CAPTION
            return INSERTION_MODE_IN_CAPTION
          when TAG_COLGROUP
            return INSERTION_MODE_IN_COLUMN_GROUP
          when TAG_TABLE
            return INSERTION_MODE_IN_TABLE
          when TAG_TEMPLATE
            return current_template_insertion_mode
          when TAG_HEAD
            return INSERTION_MODE_IN_HEAD unless is_last
          when TAG_BODY
            return INSERTION_MODE_IN_BODY
          when TAG_FRAMESET
            return INSERTION_MODE_IN_FRAMESET
          when TAG_HTML
            return @head_element ? INSERTION_MODE_AFTER_HEAD : INSERTION_MODE_BEFORE_HEAD
          end
          is_last ? INSERTION_MODE_IN_BODY : INSERTION_MODE_INITIAL
        end

        def reset_insertion_mode_appropriately
          i = @open_elements.length - 1
          while i >= 0
            mode = get_appropriate_insertion_mode(i)
            if mode != INSERTION_MODE_INITIAL
              @insertion_mode = mode
              return
            end
            i -= 1
          end
        end

        # ---- errors -----------------------------------------------------------------------

        def parser_add_parse_error(token)
          error = add_error
          return unless error

          error.type = ERR_PARSER
          error.line = token.line
          error.column = token.column
          error.offset = token.offset
          error.orig_start = token.orig_start
          error.orig_len = token.orig_len
          error.input_type = token.type
          error.input_tag = TAG_UNKNOWN
          error.input_name = nil
          if token.type == TOKEN_START_TAG || token.type == TOKEN_END_TAG
            error.input_tag = token.tag
            error.input_name = token.name.dup if token.tag == TAG_UNKNOWN && token.name
          end
          error.parser_state = @insertion_mode
          error.tag_stack = @open_elements.map do |node|
            node.tag == TAG_UNKNOWN && node.name ? node.name.dup : node.tag
          end
        end

        def is_mathml_integration_point(node)
          node_tag_in_set(node, MATHML_INTEGRATION_POINT_TAGS)
        end

        def is_html_integration_point(node)
          return true if node_tag_in_set(node, HTML_INTEGRATION_POINT_SVG_TAGS)

          if node_qualified_tag_is(node, NAMESPACE_MATHML, TAG_ANNOTATION_XML)
            attributes = node.attributes
            if attribute_matches(attributes, S_ENCODING, S_TEXT_HTML) ||
                attribute_matches(attributes, S_ENCODING, S_APP_XHTML)
              return true
            end
          end
          false
        end

        # ---- insertion ----------------------------------------------------------------------

        # returns [target, index]
        def get_appropriate_insertion_location(override_target)
          target = override_target
          if target.nil?
            target = @output.root ? current_node : document_node
          end
          if !@foster_parent_insertions || !node_tag_in_set(target, FOSTER_TARGET_TAGS)
            return [target, -1]
          end

          last_template_index = -1
          last_table_index = -1
          open_elements = @open_elements
          open_elements.each_with_index do |node, i|
            last_template_index = i if node_html_tag_is(node, TAG_TEMPLATE)
            last_table_index = i if node_html_tag_is(node, TAG_TABLE)
          end
          if last_template_index != -1 && (last_table_index == -1 || last_template_index > last_table_index)
            return [open_elements[last_template_index], -1]
          end
          return [open_elements[0], -1] if last_table_index == -1

          last_table = open_elements[last_table_index]
          if last_table.parent
            return [last_table.parent, last_table.index_within_parent]
          end

          [open_elements[last_table_index - 1], -1]
        end

        def append_node(parent, node)
          children = parent.children
          node.parent = parent
          node.index_within_parent = children.length
          children << node
        end

        def insert_node(node, target, index)
          if index != -1
            children = target.children
            node.parent = target
            node.index_within_parent = index
            children.insert(index, node)
            i = index + 1
            n = children.length
            while i < n
              children[i].index_within_parent = i
              i += 1
            end
          else
            append_node(target, node)
          end
        end

        def maybe_flush_text_node_buffer
          buffer = @text_buffer
          return if buffer.empty?

          text_node = Node.new(@text_type)
          text_node.text = buffer.dup
          text_node.line = @text_start_line

          if @foster_parent_insertions
            target, index = get_appropriate_insertion_location(nil)
            insert_node(text_node, target, index) unless target.type == NODE_DOCUMENT
          elsif @output.root
            # (get_appropriate_insertion_location without foster parenting: the current node)
            target = @open_elements[-1]
            append_node(target, text_node) unless target.type == NODE_DOCUMENT
          end

          buffer.clear
          @text_type = NODE_WHITESPACE
        end

        def pop_current_node
          maybe_flush_text_node_buffer
          @open_elements.pop
        end

        def append_comment_node(node, token)
          maybe_flush_text_node_buffer
          comment = Node.new(NODE_COMMENT)
          comment.text = token.text
          comment.line = token.line
          append_node(node, comment)
        end

        def clear_stack_to_table_row_context
          pop_current_node until node_tag_in_set(current_node, TABLE_ROW_CONTEXT_TAGS)
        end

        def clear_stack_to_table_context
          pop_current_node until node_tag_in_set(current_node, TABLE_CONTEXT_TAGS)
        end

        def clear_stack_to_table_body_context
          pop_current_node until node_tag_in_set(current_node, TABLE_BODY_CONTEXT_TAGS)
        end

        def create_element(tag)
          node = Node.new(NODE_ELEMENT)
          node.children = []
          node.attributes = []
          node.tag = tag
          node.name = TAG_NAMES[tag]
          node.tag_namespace = NAMESPACE_HTML
          node.line = @current_token ? @current_token.line : 0
          node
        end

        def create_element_from_token(token, tag_namespace)
          type = tag_namespace == NAMESPACE_HTML && token.tag == TAG_TEMPLATE ? NODE_TEMPLATE : NODE_ELEMENT
          node = Node.new(type)
          node.children = []
          node.attributes = token.attributes
          node.tag = token.tag
          node.name = token.name || TAG_NAMES[token.tag]
          node.tag_namespace = tag_namespace
          node.line = token.line
          token.attributes = []
          token.name = nil
          node
        end

        def insert_element(node, is_reconstructing_formatting_elements)
          maybe_flush_text_node_buffer unless is_reconstructing_formatting_elements
          if @foster_parent_insertions
            target, index = get_appropriate_insertion_location(nil)
            insert_node(node, target, index)
          else
            append_node(@output.root ? @open_elements[-1] : @output.document, node)
          end
          @open_elements << node
        end

        def insert_element_from_token(token)
          element = create_element_from_token(token, NAMESPACE_HTML)
          insert_element(element, false)
          element
        end

        def insert_element_of_tag_type(tag)
          element = create_element(tag)
          insert_element(element, false)
          element
        end

        def insert_foreign_element(token, tag_namespace)
          element = create_element_from_token(token, tag_namespace)
          insert_element(element, false)
          # These checks look at the token's attributes, which create_element_from_token has
          # just moved to the element, so (as in gumbo) they never fire.
          if token_has_attribute(token, S_XMLNS) &&
              !attribute_matches_case_sensitive(token.attributes, S_XMLNS, LEGAL_XMLNS[tag_namespace])
            parser_add_parse_error(token)
          end
          if token_has_attribute(token, S_XMLNS_XLINK) &&
              !attribute_matches_case_sensitive(token.attributes, S_XMLNS_XLINK, S_XLINK_NS)
            parser_add_parse_error(token)
          end
          element
        end

        def insert_text_token(token)
          buffer = @text_buffer
          @text_start_line = token.line if buffer.empty?
          c = token.character
          if c < 0x80
            buffer << c
          else
            Util.append_codepoint(buffer, c)
          end
          type = token.type
          if type == TOKEN_CHARACTER
            @text_type = NODE_TEXT
          elsif type == TOKEN_CDATA
            @text_type = NODE_CDATA
          end
        end

        def run_generic_parsing_algorithm(token, lexer_state)
          insert_element_from_token(token)
          @tokenizer.set_state(lexer_state)
          @original_insertion_mode = @insertion_mode
          @insertion_mode = INSERTION_MODE_TEXT
        end

        def acknowledge_self_closing_tag
          @self_closing_flag_acknowledged = true
        end

        # returns the index or nil
        def find_last_anchor_index
          elements = @active_formatting_elements
          i = elements.length - 1
          while i >= 0
            node = elements[i]
            return nil if node.equal?(MARKER)
            return i if node_html_tag_is(node, TAG_A)

            i -= 1
          end
          nil
        end

        # returns [count, earliest_matching_index]
        def count_formatting_elements_of_tag(desired_node, earliest_matching_index)
          elements = @active_formatting_elements
          num_identical_elements = 0
          i = elements.length - 1
          while i >= 0
            node = elements[i]
            break if node.equal?(MARKER)

            if node_qualified_tagname_is(node, desired_node.tag_namespace, desired_node.tag, desired_node.name) &&
                all_attributes_match(node.attributes, desired_node.attributes)
              num_identical_elements += 1
              earliest_matching_index = i
            end
            i -= 1
          end
          [num_identical_elements, earliest_matching_index]
        end

        def add_formatting_element(node)
          elements = @active_formatting_elements
          num_identical_elements, earliest = count_formatting_elements_of_tag(node, elements.length)
          elements.delete_at(earliest) if num_identical_elements >= 3
          elements << node
        end

        def is_open_element(node)
          @open_elements.any? { |n| n.equal?(node) }
        end

        def clone_node(node)
          new_node = Node.new(node.type)
          new_node.children = []
          new_node.tag = node.tag
          new_node.name = node.name
          new_node.tag_namespace = node.tag_namespace
          new_node.line = node.line
          new_node.attributes = node.attributes.map do |old|
            a = Attribute.new(old.name.dup, old.value.dup, old.orig_name_len)
            a.attr_namespace = old.attr_namespace
            a
          end
          new_node
        end

        def reconstruct_active_formatting_elements
          elements = @active_formatting_elements
          return if elements.empty?

          i = elements.length - 1
          element = elements[i]
          return if element.equal?(MARKER) || is_open_element(element)

          loop do
            if i == 0
              i = -1
              break
            end
            i -= 1
            element = elements[i]
            break if element.equal?(MARKER) || is_open_element(element)
          end

          i += 1
          while i < elements.length
            element = elements[i]
            clone = clone_node(element)
            target, index = get_appropriate_insertion_location(nil)
            insert_node(clone, target, index)
            @open_elements << clone
            elements[i] = clone
            i += 1
          end
        end

        def clear_active_formatting_elements
          elements = @active_formatting_elements
          loop do
            node = elements.pop
            break if node.nil? || node.equal?(MARKER)
          end
        end

        def compute_quirks_mode(doctype)
          return DOCTYPE_QUIRKS if doctype.force_quirks

          Gumbo.compute_quirks_mode(
            doctype.name,
            doctype.has_public_identifier ? doctype.public_identifier : nil,
            doctype.has_system_identifier ? doctype.system_identifier : nil,
          )
        end

        # gumbo_compute_quirks_mode (name/pubid/sysid may be nil)
        def self.compute_quirks_mode(name, pubid, sysid)
          name = name&.b
          pubid = pubid&.b
          sysid = sysid&.b
          pubid = pubid.byteslice(0, pubid.index("\0")) if pubid&.include?("\0")
          sysid = sysid.byteslice(0, sysid.index("\0")) if sysid&.include?("\0")
          p = new_static_list_checker
          has_system_identifier = !sysid.nil?
          if name.nil? || cstr_s(name) != S_HTML ||
              p.call(pubid, QUIRKS_MODE_PUBLIC_ID_PREFIXES, false) ||
              p.call(pubid, QUIRKS_MODE_PUBLIC_ID_EXACT_MATCHES, true) ||
              p.call(sysid, QUIRKS_MODE_SYSTEM_ID_EXACT_MATCHES, true) ||
              (!has_system_identifier && p.call(pubid, SYSTEM_ID_DEPENDENT_PUBLIC_ID_PREFIXES, false))
            return DOCTYPE_QUIRKS
          end

          if p.call(pubid, LIMITED_QUIRKS_PUBLIC_ID_PREFIXES, false) ||
              (has_system_identifier && p.call(pubid, SYSTEM_ID_DEPENDENT_PUBLIC_ID_PREFIXES, false))
            return DOCTYPE_LIMITED_QUIRKS
          end

          DOCTYPE_NO_QUIRKS
        end

        def self.cstr_s(s)
          i = s.index("\0")
          i ? s.byteslice(0, i) : s
        end

        def self.new_static_list_checker
          lambda do |needle, haystack, exact_match|
            next false if needle.nil? || needle.empty?

            if exact_match
              haystack.any? { |s| s.bytesize == needle.bytesize && s.casecmp(needle) == 0 }
            else
              haystack.any? do |s|
                needle.bytesize >= s.bytesize && needle.byteslice(0, s.bytesize).casecmp(s) == 0
              end
            end
          end
        end

        # ---- scopes ------------------------------------------------------------------------

        def has_an_element_in_specific_scope(expected, negate, tags)
          open_elements = @open_elements
          i = open_elements.length - 1
          while i >= 0
            node = open_elements[i]
            i -= 1
            t = node.type
            next unless t == NODE_ELEMENT || t == NODE_TEMPLATE

            node_tag = node.tag
            node_ns = node.tag_namespace
            if node_ns == NAMESPACE_HTML
              if expected.is_a?(Integer)
                return true if node_tag == expected
              elsif expected.include?(node_tag)
                return true
              end
            end
            found = (tags[node_tag] & (1 << node_ns)) != 0
            return false if negate != found
          end
          false
        end

        def has_open_element(tag)
          has_an_element_in_specific_scope(tag, false, HTML_ONLY_TAGS)
        end

        def has_an_element_in_scope(tag)
          has_an_element_in_specific_scope(tag, false, DEFAULT_SCOPE_TAGS)
        end

        def has_node_in_scope(node)
          open_elements = @open_elements
          i = open_elements.length - 1
          while i >= 0
            current = open_elements[i]
            i -= 1
            return true if current.equal?(node)

            t = current.type
            next unless t == NODE_ELEMENT || t == NODE_TEMPLATE
            return false if node_tag_in_set(current, DEFAULT_SCOPE_TAGS)
          end
          false
        end

        def has_an_element_in_scope_with_tagname(expected)
          has_an_element_in_specific_scope(expected, false, DEFAULT_SCOPE_TAGS)
        end

        def has_an_element_in_list_scope(tag)
          has_an_element_in_specific_scope(tag, false, LIST_SCOPE_TAGS)
        end

        def has_an_element_in_button_scope(tag)
          has_an_element_in_specific_scope(tag, false, BUTTON_SCOPE_TAGS)
        end

        def has_an_element_in_table_scope(tag)
          has_an_element_in_specific_scope(tag, false, TABLE_SCOPE_TAGS)
        end

        def has_an_element_in_select_scope(tag)
          has_an_element_in_specific_scope(tag, true, SELECT_SCOPE_TAGS)
        end

        def generate_implied_end_tags(exception, exception_name)
          while node_tag_in_set(current_node, IMPLIED_END_TAGS) &&
              !node_html_tagname_is(current_node, exception, exception_name)
            pop_current_node
          end
        end

        def generate_all_implied_end_tags_thoroughly
          pop_current_node while node_tag_in_set(current_node, THOROUGH_IMPLIED_END_TAGS)
        end

        def stack_contains_nonclosable_element
          @open_elements.any? { |node| !node_tag_in_set(node, NONCLOSABLE_OK_TAGS) }
        end

        def close_table
          return false unless has_an_element_in_table_scope(TAG_TABLE)

          node = pop_current_node
          node = pop_current_node until node_html_tag_is(node, TAG_TABLE)
          reset_insertion_mode_appropriately
          true
        end

        def close_table_cell(token, cell_tag)
          generate_implied_end_tags(TAG_LAST, nil)
          node = current_node
          parser_add_parse_error(token) unless node_html_tag_is(node, cell_tag)
          loop do
            node = pop_current_node
            break if node_html_tag_is(node, cell_tag)
          end
          clear_active_formatting_elements
          @insertion_mode = INSERTION_MODE_IN_ROW
        end

        def close_current_cell(token)
          cell_tag = has_an_element_in_table_scope(TAG_TD) ? TAG_TD : TAG_TH
          close_table_cell(token, cell_tag)
        end

        def close_current_select
          node = pop_current_node
          node = pop_current_node until node_html_tag_is(node, TAG_SELECT)
          reset_insertion_mode_appropriately
        end

        def is_special_node(node)
          node_tag_in_set(node, SPECIAL_TAGS)
        end

        def implicitly_close_tags(token, target_ns, target)
          generate_implied_end_tags(target, nil)
          unless node_qualified_tag_is(current_node, target_ns, target)
            parser_add_parse_error(token)
            pop_current_node until node_qualified_tag_is(current_node, target_ns, target)
          end
          pop_current_node
        end

        def maybe_implicitly_close_p_tag(token)
          if has_an_element_in_button_scope(TAG_P)
            implicitly_close_tags(token, NAMESPACE_HTML, TAG_P)
          end
        end

        def maybe_implicitly_close_list_tag(token, is_li)
          set_frameset_not_ok
          open_elements = @open_elements
          i = open_elements.length - 1
          while i >= 0
            node = open_elements[i]
            is_list_tag = is_li ? node_html_tag_is(node, TAG_LI) : node_tag_in_set(node, DD_DT_TAGS)
            if is_list_tag
              implicitly_close_tags(token, node.tag_namespace, node.tag)
              return
            end
            return if is_special_node(node) && !node_tag_in_set(node, ADDRESS_DIV_P_TAGS)

            i -= 1
          end
        end

        def merge_attributes(token, node)
          node_attr = node.attributes
          token.attributes.each do |attr|
            node_attr << attr unless get_attribute(node_attr, attr.name)
          end
          token.attributes = []
        end

        def adjust_foreign_attributes(token)
          token.attributes.each do |attr|
            entry = FOREIGN_ATTR_REPLACEMENTS[cstr(attr.name)]
            next unless entry

            attr.attr_namespace = entry[1]
            attr.name = entry[0].dup
          end
        end

        def adjust_svg_tag(token)
          if token.tag == TAG_FOREIGNOBJECT
            token.name = S_FOREIGN_OBJECT
          elsif token.tag == TAG_UNKNOWN
            replacement = SVG_TAG_REPLACEMENTS[token.name.downcase(:ascii)]
            token.name = replacement.dup if replacement
          end
        end

        def adjust_svg_attributes(token)
          token.attributes.each do |attr|
            name = attr.name
            len = attr.orig_name_len
            # gperf lookup of (attr->name, original_name.length)
            key = if len <= name.bytesize
              name.byteslice(0, len)
            end
            next if key.nil? || key.include?("\0")

            replacement = SVG_ATTR_REPLACEMENTS[key.downcase(:ascii)]
            next unless replacement

            attr.name = replacement.dup
          end
        end

        def adjust_mathml_attributes(token)
          attr = get_attribute(token.attributes, S_DEFINITIONURL)
          return unless attr

          attr.name = S_DEFINITION_URL.dup
        end

        def maybe_add_doctype_error(token)
          doctype = token.doc_type
          if cstr(doctype.name) != S_HTML || doctype.has_public_identifier ||
              (doctype.has_system_identifier && cstr(doctype.system_identifier) != S_ABOUT_LEGACY_COMPAT)
            parser_add_parse_error(token)
          end
        end

        def remove_from_parent(node)
          parent = node.parent
          return unless parent

          children = parent.children
          index = children.index { |c| c.equal?(node) }
          children.delete_at(index)
          node.parent = nil
          node.index_within_parent = -1
          i = index
          n = children.length
          while i < n
            children[i].index_within_parent = i
            i += 1
          end
        end

        def ignore_token
          # nothing to free in Ruby
        end

        def in_body_any_other_end_tag(token)
          tag = token.tag
          tagname = token.name
          open_elements = @open_elements
          i = open_elements.length - 1
          while i >= 0
            node = open_elements[i]
            if node_qualified_tagname_is(node, NAMESPACE_HTML, tag, tagname)
              generate_implied_end_tags(tag, tagname)
              parser_add_parse_error(token) unless node.equal?(current_node)
              until node.equal?(pop_current_node)
              end
              return
            elsif is_special_node(node)
              parser_add_parse_error(token)
              ignore_token
              return
            end
            i -= 1
          end
        end

        def index_of(vector, element)
          vector.index { |e| e.equal?(element) } || -1
        end

        def vector_remove(vector, element)
          i = index_of(vector, element)
          vector.delete_at(i) if i != -1
        end

        def adoption_agency_algorithm(token)
          subject = token.tag
          afe = @active_formatting_elements
          open_elements = @open_elements

          # Step 2.
          cur = current_node
          if node_html_tag_is(cur, subject) && index_of(afe, cur) == -1
            pop_current_node
            return
          end

          8.times do
            # Step 6.
            formatting_node = nil
            formatting_node_in_open_elements = -1
            j = afe.length - 1
            while j >= 0
              n = afe[j]
              break if n.equal?(MARKER)

              if node_html_tag_is(n, subject)
                formatting_node = n
                formatting_node_in_open_elements = index_of(open_elements, formatting_node)
                break
              end
              j -= 1
            end
            unless formatting_node
              in_body_any_other_end_tag(token)
              return
            end

            # Step 7
            if formatting_node_in_open_elements == -1
              parser_add_parse_error(token)
              vector_remove(afe, formatting_node)
              return
            end

            # Step 8
            unless has_an_element_in_scope(formatting_node.tag)
              parser_add_parse_error(token)
              return
            end

            # Step 9
            parser_add_parse_error(token) unless formatting_node.equal?(current_node)

            # Step 10
            furthest_block = nil
            j = formatting_node_in_open_elements
            while j < open_elements.length
              c = open_elements[j]
              if is_special_node(c)
                furthest_block = c
                break
              end
              j += 1
            end
            # Step 11.
            unless furthest_block
              until pop_current_node.equal?(formatting_node)
              end
              vector_remove(afe, formatting_node)
              return
            end

            # Step 12.
            common_ancestor = open_elements[formatting_node_in_open_elements - 1]

            # Step 13.
            bookmark = 1 + index_of(afe, formatting_node)
            # Step 14.
            node = furthest_block
            last_node = furthest_block
            saved_node_index = index_of(open_elements, node)
            j = 0
            loop do
              j += 1
              node_index = index_of(open_elements, node)
              node_index = saved_node_index if node_index == -1
              node_index -= 1
              saved_node_index = node_index
              node = open_elements[node_index]
              break if node.equal?(formatting_node)

              formatting_index = index_of(afe, node)
              if j > 3 && formatting_index != -1
                afe.delete_at(formatting_index)
                bookmark -= 1 if formatting_index < bookmark
                next
              end
              if formatting_index == -1
                open_elements.delete_at(node_index)
                next
              end
              node = clone_node(node)
              afe[formatting_index] = node
              open_elements[node_index] = node
              bookmark = formatting_index + 1 if last_node.equal?(furthest_block)
              remove_from_parent(last_node)
              append_node(node, last_node)
              last_node = node
            end

            # Step 15.
            remove_from_parent(last_node)
            target, index = get_appropriate_insertion_location(common_ancestor)
            insert_node(last_node, target, index)

            # Step 16.
            new_formatting_node = clone_node(formatting_node)

            # Step 17.
            temp = new_formatting_node.children
            new_formatting_node.children = furthest_block.children
            furthest_block.children = temp
            new_formatting_node.children.each { |child| child.parent = new_formatting_node }

            # Step 18.
            append_node(furthest_block, new_formatting_node)

            # Step 19.
            formatting_node_index = index_of(afe, formatting_node)
            bookmark -= 1 if formatting_node_index < bookmark
            afe.delete_at(formatting_node_index)
            afe.insert(bookmark, new_formatting_node)

            # Step 20.
            vector_remove(open_elements, formatting_node)
            insert_at = 1 + index_of(open_elements, furthest_block)
            open_elements.insert(insert_at, new_formatting_node)
          end
        end

        def finish_parsing
          maybe_flush_text_node_buffer
          while pop_current_node
          end
          while pop_current_node
          end
        end

        # ---- insertion modes ------------------------------------------------------------

        def handle_initial(token)
          document = document_node
          type = token.type
          if type == TOKEN_WHITESPACE
            ignore_token
            return
          end
          if type == TOKEN_COMMENT
            append_comment_node(document, token)
            return
          end
          if type == TOKEN_DOCTYPE
            dt = token.doc_type
            document.has_doctype = true
            document.doc_name = dt.name
            document.public_identifier = dt.public_identifier
            document.system_identifier = dt.system_identifier
            document.doc_type_quirks_mode = compute_quirks_mode(dt)
            @insertion_mode = INSERTION_MODE_BEFORE_HTML
            maybe_add_doctype_error(token)
            return
          end
          parser_add_parse_error(token)
          document.doc_type_quirks_mode = DOCTYPE_QUIRKS
          @insertion_mode = INSERTION_MODE_BEFORE_HTML
          @reprocess_current_token = true
        end

        def handle_before_html(token)
          type = token.type
          if type == TOKEN_DOCTYPE
            parser_add_parse_error(token)
            ignore_token
            return
          end
          if type == TOKEN_COMMENT
            append_comment_node(document_node, token)
            return
          end
          if type == TOKEN_WHITESPACE
            ignore_token
            return
          end
          if start_tag_is(token, TAG_HTML)
            html_node = insert_element_from_token(token)
            @output.root = html_node
            @insertion_mode = INSERTION_MODE_BEFORE_HEAD
            return
          end
          if type == TOKEN_END_TAG && !end_tag_in(token, HEAD_BODY_HTML_BR)
            parser_add_parse_error(token)
            ignore_token
            return
          end
          html_node = insert_element_of_tag_type(TAG_HTML)
          @output.root = html_node
          @insertion_mode = INSERTION_MODE_BEFORE_HEAD
          @reprocess_current_token = true
        end

        def handle_before_head(token)
          type = token.type
          if type == TOKEN_WHITESPACE
            ignore_token
            return
          end
          if type == TOKEN_COMMENT
            append_comment_node(current_node, token)
            return
          end
          if type == TOKEN_DOCTYPE
            parser_add_parse_error(token)
            ignore_token
            return
          end
          if start_tag_is(token, TAG_HTML)
            handle_in_body(token)
            return
          end
          if start_tag_is(token, TAG_HEAD)
            node = insert_element_from_token(token)
            @head_element = node
            @insertion_mode = INSERTION_MODE_IN_HEAD
            return
          end
          if type == TOKEN_END_TAG && !end_tag_in(token, HEAD_BODY_HTML_BR)
            parser_add_parse_error(token)
            ignore_token
            return
          end
          node = insert_element_of_tag_type(TAG_HEAD)
          @head_element = node
          @insertion_mode = INSERTION_MODE_IN_HEAD
          @reprocess_current_token = true
        end

        def handle_in_head(token)
          type = token.type
          if type == TOKEN_WHITESPACE
            insert_text_token(token)
            return
          end
          if type == TOKEN_COMMENT
            append_comment_node(current_node, token)
            return
          end
          if type == TOKEN_DOCTYPE
            parser_add_parse_error(token)
            ignore_token
            return
          end
          if start_tag_is(token, TAG_HTML)
            handle_in_body(token)
            return
          end
          if start_tag_in(token, IN_HEAD_VOID)
            insert_element_from_token(token)
            pop_current_node
            acknowledge_self_closing_tag
            return
          end
          if start_tag_is(token, TAG_META)
            insert_element_from_token(token)
            pop_current_node
            acknowledge_self_closing_tag
            return
          end
          if start_tag_is(token, TAG_TITLE)
            run_generic_parsing_algorithm(token, LEX_RCDATA)
            return
          end
          if start_tag_in(token, NOFRAMES_STYLE) ||
              (start_tag_is(token, TAG_NOSCRIPT) && @options.parse_noscript_content_as_text)
            run_generic_parsing_algorithm(token, LEX_RAWTEXT)
            return
          end
          if start_tag_is(token, TAG_NOSCRIPT)
            insert_element_from_token(token)
            @insertion_mode = INSERTION_MODE_IN_HEAD_NOSCRIPT
            return
          end
          if start_tag_is(token, TAG_SCRIPT)
            run_generic_parsing_algorithm(token, LEX_SCRIPT_DATA)
            return
          end
          if end_tag_is(token, TAG_HEAD)
            pop_current_node
            @insertion_mode = INSERTION_MODE_AFTER_HEAD
            return
          end
          if end_tag_in(token, BODY_HTML_BR)
            pop_current_node
            @insertion_mode = INSERTION_MODE_AFTER_HEAD
            @reprocess_current_token = true
            return
          end
          if start_tag_is(token, TAG_TEMPLATE)
            insert_element_from_token(token)
            add_formatting_element(MARKER)
            set_frameset_not_ok
            @insertion_mode = INSERTION_MODE_IN_TEMPLATE
            push_template_insertion_mode(INSERTION_MODE_IN_TEMPLATE)
            return
          end
          if end_tag_is(token, TAG_TEMPLATE)
            unless has_open_element(TAG_TEMPLATE)
              parser_add_parse_error(token)
              ignore_token
              return
            end
            generate_all_implied_end_tags_thoroughly
            parser_add_parse_error(token) unless node_html_tag_is(current_node, TAG_TEMPLATE)
            until node_html_tag_is(pop_current_node, TAG_TEMPLATE)
            end
            clear_active_formatting_elements
            pop_template_insertion_mode
            reset_insertion_mode_appropriately
            return
          end
          if start_tag_is(token, TAG_HEAD) || type == TOKEN_END_TAG
            parser_add_parse_error(token)
            ignore_token
            return
          end
          pop_current_node
          @insertion_mode = INSERTION_MODE_AFTER_HEAD
          @reprocess_current_token = true
        end

        def handle_in_head_noscript(token)
          type = token.type
          if type == TOKEN_DOCTYPE
            parser_add_parse_error(token)
            ignore_token
            return
          end
          if start_tag_is(token, TAG_HTML)
            handle_in_body(token)
            return
          end
          if end_tag_is(token, TAG_NOSCRIPT)
            pop_current_node
            @insertion_mode = INSERTION_MODE_IN_HEAD
            return
          end
          if type == TOKEN_WHITESPACE || type == TOKEN_COMMENT || start_tag_in(token, IN_HEAD_NOSCRIPT_HEAD_TAGS)
            handle_in_head(token)
            return
          end
          if start_tag_in(token, HEAD_NOSCRIPT) || (type == TOKEN_END_TAG && !end_tag_is(token, TAG_BR))
            parser_add_parse_error(token)
            ignore_token
            return
          end
          parser_add_parse_error(token)
          pop_current_node
          @insertion_mode = INSERTION_MODE_IN_HEAD
          @reprocess_current_token = true
        end

        def handle_after_head(token)
          type = token.type
          if type == TOKEN_WHITESPACE
            insert_text_token(token)
            return
          end
          if type == TOKEN_COMMENT
            append_comment_node(current_node, token)
            return
          end
          if type == TOKEN_DOCTYPE
            parser_add_parse_error(token)
            ignore_token
            return
          end
          if start_tag_is(token, TAG_HTML)
            handle_in_body(token)
            return
          end
          if start_tag_is(token, TAG_BODY)
            insert_element_from_token(token)
            set_frameset_not_ok
            @insertion_mode = INSERTION_MODE_IN_BODY
            return
          end
          if start_tag_is(token, TAG_FRAMESET)
            insert_element_from_token(token)
            @insertion_mode = INSERTION_MODE_IN_FRAMESET
            return
          end
          if start_tag_in(token, AFTER_HEAD_HEAD_TAGS)
            parser_add_parse_error(token)
            maybe_flush_text_node_buffer
            @open_elements << @head_element
            handle_in_head(token)
            vector_remove(@open_elements, @head_element)
            return
          end
          if end_tag_is(token, TAG_TEMPLATE)
            handle_in_head(token)
            return
          end
          if start_tag_is(token, TAG_HEAD) || (type == TOKEN_END_TAG && !end_tag_in(token, BODY_HTML_BR))
            parser_add_parse_error(token)
            ignore_token
            return
          end
          insert_element_of_tag_type(TAG_BODY)
          @insertion_mode = INSERTION_MODE_IN_BODY
          @reprocess_current_token = true
        end

        def handle_in_body(token)
          type = token.type
          if type == TOKEN_NULL
            parser_add_parse_error(token)
            ignore_token
            return
          end
          if type == TOKEN_WHITESPACE
            reconstruct_active_formatting_elements
            insert_text_token(token)
            return
          end
          if type == TOKEN_CHARACTER || type == TOKEN_CDATA
            reconstruct_active_formatting_elements
            insert_text_token(token)
            set_frameset_not_ok
            return
          end
          if type == TOKEN_COMMENT
            append_comment_node(current_node, token)
            return
          end
          if type == TOKEN_DOCTYPE
            parser_add_parse_error(token)
            ignore_token
            return
          end
          if type == TOKEN_EOF
            if current_template_insertion_mode != INSERTION_MODE_INITIAL
              handle_in_template(token)
              return
            end
            parser_add_parse_error(token) if stack_contains_nonclosable_element
            return
          end
          if type == TOKEN_START_TAG
            handle_in_body_start_tag(token)
          else
            handle_in_body_end_tag(token)
          end
        end

        def handle_in_body_start_tag(token)
          tag = token.tag
          if tag == TAG_HTML
            parser_add_parse_error(token)
            if has_open_element(TAG_TEMPLATE)
              ignore_token
              return
            end
            merge_attributes(token, @output.root)
            return
          end
          if IN_BODY_HEAD_TAGS[tag] != 0
            handle_in_head(token)
            return
          end
          if tag == TAG_BODY
            parser_add_parse_error(token)
            if @open_elements.length < 2 || !node_html_tag_is(@open_elements[1], TAG_BODY) ||
                has_open_element(TAG_TEMPLATE)
              ignore_token
            else
              set_frameset_not_ok
              merge_attributes(token, @open_elements[1])
            end
            return
          end
          if tag == TAG_FRAMESET
            parser_add_parse_error(token)
            if @open_elements.length < 2 || !node_html_tag_is(@open_elements[1], TAG_BODY) || !@frameset_ok
              ignore_token
              return
            end
            body_node = @open_elements[1]
            # (C compares against the stale open_elements.data[1] slot, which still holds body)
            loop do
              node = pop_current_node
              break if node.equal?(body_node)
            end
            clear_active_formatting_elements
            # removed without renumbering the following siblings' index_within_parent, as in C
            children = @output.root.children
            idx = children.index { |c| c.equal?(body_node) }
            children.delete_at(idx) if idx
            insert_element_from_token(token)
            @insertion_mode = INSERTION_MODE_IN_FRAMESET
            return
          end
          if IN_BODY_BLOCK_START[tag] != 0
            maybe_implicitly_close_p_tag(token)
            insert_element_from_token(token)
            return
          end
          if HEADING_TAGS[tag] != 0
            maybe_implicitly_close_p_tag(token)
            if node_tag_in_set(current_node, HEADING_TAGS)
              parser_add_parse_error(token)
              pop_current_node
            end
            insert_element_from_token(token)
            return
          end
          if PRE_LISTING[tag] != 0
            maybe_implicitly_close_p_tag(token)
            insert_element_from_token(token)
            @ignore_next_linefeed = true
            set_frameset_not_ok
            return
          end
          if tag == TAG_FORM
            if @form_element && !has_open_element(TAG_TEMPLATE)
              parser_add_parse_error(token)
              ignore_token
              return
            end
            maybe_implicitly_close_p_tag(token)
            form_element = insert_element_from_token(token)
            @form_element = form_element unless has_open_element(TAG_TEMPLATE)
            return
          end
          if tag == TAG_LI
            maybe_implicitly_close_list_tag(token, true)
            maybe_implicitly_close_p_tag(token)
            insert_element_from_token(token)
            return
          end
          if DD_DT_TAGS[tag] != 0
            maybe_implicitly_close_list_tag(token, false)
            maybe_implicitly_close_p_tag(token)
            insert_element_from_token(token)
            return
          end
          if tag == TAG_PLAINTEXT
            maybe_implicitly_close_p_tag(token)
            insert_element_from_token(token)
            @tokenizer.set_state(LEX_PLAINTEXT)
            return
          end
          if tag == TAG_BUTTON
            if has_an_element_in_scope(TAG_BUTTON)
              parser_add_parse_error(token)
              generate_implied_end_tags(TAG_LAST, nil)
              until node_html_tag_is(pop_current_node, TAG_BUTTON)
              end
            end
            reconstruct_active_formatting_elements
            insert_element_from_token(token)
            set_frameset_not_ok
            return
          end
          if tag == TAG_A
            if find_last_anchor_index
              parser_add_parse_error(token)
              adoption_agency_algorithm(token)
              if (last_a = find_last_anchor_index)
                last_element = @active_formatting_elements.delete_at(last_a)
                vector_remove(@open_elements, last_element)
              end
            end
            reconstruct_active_formatting_elements
            add_formatting_element(insert_element_from_token(token))
            return
          end
          if FORMATTING_START[tag] != 0
            reconstruct_active_formatting_elements
            add_formatting_element(insert_element_from_token(token))
            return
          end
          if tag == TAG_NOBR
            reconstruct_active_formatting_elements
            if has_an_element_in_scope(TAG_NOBR)
              parser_add_parse_error(token)
              adoption_agency_algorithm(token)
              reconstruct_active_formatting_elements
            end
            insert_element_from_token(token)
            add_formatting_element(current_node)
            return
          end
          if APPLET_MARQUEE_OBJECT[tag] != 0
            reconstruct_active_formatting_elements
            insert_element_from_token(token)
            add_formatting_element(MARKER)
            set_frameset_not_ok
            return
          end
          if tag == TAG_TABLE
            if document_node.doc_type_quirks_mode != DOCTYPE_QUIRKS
              maybe_implicitly_close_p_tag(token)
            end
            insert_element_from_token(token)
            set_frameset_not_ok
            @insertion_mode = INSERTION_MODE_IN_TABLE
            return
          end
          if IN_BODY_VOID[tag] != 0
            is_image = tag == TAG_IMAGE
            if is_image
              parser_add_parse_error(token)
              token.tag = TAG_IMG
            end
            reconstruct_active_formatting_elements
            insert_element_from_token(token)
            pop_current_node
            acknowledge_self_closing_tag
            set_frameset_not_ok
            return
          end
          if tag == TAG_INPUT
            reconstruct_active_formatting_elements
            input = insert_element_from_token(token)
            pop_current_node
            acknowledge_self_closing_tag
            set_frameset_not_ok unless attribute_matches(input.attributes, S_TYPE, S_HIDDEN)
            return
          end
          if PARAM_SOURCE_TRACK[tag] != 0
            insert_element_from_token(token)
            pop_current_node
            acknowledge_self_closing_tag
            return
          end
          if tag == TAG_HR
            maybe_implicitly_close_p_tag(token)
            insert_element_from_token(token)
            pop_current_node
            acknowledge_self_closing_tag
            set_frameset_not_ok
            return
          end
          if tag == TAG_TEXTAREA
            run_generic_parsing_algorithm(token, LEX_RCDATA)
            @ignore_next_linefeed = true
            set_frameset_not_ok
            return
          end
          if tag == TAG_XMP
            maybe_implicitly_close_p_tag(token)
            reconstruct_active_formatting_elements
            set_frameset_not_ok
            run_generic_parsing_algorithm(token, LEX_RAWTEXT)
            return
          end
          if tag == TAG_IFRAME
            set_frameset_not_ok
            run_generic_parsing_algorithm(token, LEX_RAWTEXT)
            return
          end
          if tag == TAG_NOEMBED || (tag == TAG_NOSCRIPT && @options.parse_noscript_content_as_text)
            run_generic_parsing_algorithm(token, LEX_RAWTEXT)
            return
          end
          if tag == TAG_SELECT
            reconstruct_active_formatting_elements
            insert_element_from_token(token)
            set_frameset_not_ok
            state = @insertion_mode
            if state == INSERTION_MODE_IN_TABLE || state == INSERTION_MODE_IN_CAPTION ||
                state == INSERTION_MODE_IN_TABLE_BODY || state == INSERTION_MODE_IN_ROW ||
                state == INSERTION_MODE_IN_CELL
              @insertion_mode = INSERTION_MODE_IN_SELECT_IN_TABLE
            else
              @insertion_mode = INSERTION_MODE_IN_SELECT
            end
            return
          end
          if OPTGROUP_OPTION[tag] != 0
            pop_current_node if node_html_tag_is(current_node, TAG_OPTION)
            reconstruct_active_formatting_elements
            insert_element_from_token(token)
            return
          end
          if RB_RTC[tag] != 0
            if has_an_element_in_scope(TAG_RUBY)
              generate_implied_end_tags(TAG_LAST, nil)
              parser_add_parse_error(token) unless node_html_tag_is(current_node, TAG_RUBY)
            end
            insert_element_from_token(token)
            return
          end
          if RP_RT[tag] != 0
            if has_an_element_in_scope(TAG_RUBY)
              generate_implied_end_tags(TAG_RTC, nil)
              cur = current_node
              if !node_html_tag_is(cur, TAG_RUBY) && !node_html_tag_is(cur, TAG_RTC)
                parser_add_parse_error(token)
              end
            end
            insert_element_from_token(token)
            return
          end
          if tag == TAG_MATH
            reconstruct_active_formatting_elements
            adjust_mathml_attributes(token)
            adjust_foreign_attributes(token)
            insert_foreign_element(token, NAMESPACE_MATHML)
            if token.is_self_closing
              pop_current_node
              acknowledge_self_closing_tag
            end
            return
          end
          if tag == TAG_SVG
            reconstruct_active_formatting_elements
            adjust_svg_attributes(token)
            adjust_foreign_attributes(token)
            insert_foreign_element(token, NAMESPACE_SVG)
            if token.is_self_closing
              pop_current_node
              acknowledge_self_closing_tag
            end
            return
          end
          if IN_BODY_IGNORED_START[tag] != 0
            parser_add_parse_error(token)
            ignore_token
            return
          end
          reconstruct_active_formatting_elements
          insert_element_from_token(token)
        end

        def handle_in_body_end_tag(token)
          tag = token.tag
          if tag == TAG_TEMPLATE
            handle_in_head(token)
            return
          end
          if tag == TAG_BODY
            unless has_an_element_in_scope(TAG_BODY)
              parser_add_parse_error(token)
              ignore_token
              return
            end
            parser_add_parse_error(token) if stack_contains_nonclosable_element
            @insertion_mode = INSERTION_MODE_AFTER_BODY
            return
          end
          if tag == TAG_HTML
            unless has_an_element_in_scope(TAG_BODY)
              parser_add_parse_error(token)
              ignore_token
              return
            end
            parser_add_parse_error(token) if stack_contains_nonclosable_element
            @insertion_mode = INSERTION_MODE_AFTER_BODY
            @reprocess_current_token = true
            return
          end
          if IN_BODY_BLOCK_END[tag] != 0
            unless has_an_element_in_scope(tag)
              parser_add_parse_error(token)
              ignore_token
              return
            end
            implicitly_close_tags(token, NAMESPACE_HTML, tag)
            return
          end
          if tag == TAG_FORM
            if has_open_element(TAG_TEMPLATE)
              unless has_an_element_in_scope(TAG_FORM)
                parser_add_parse_error(token)
                ignore_token
                return
              end
              generate_implied_end_tags(TAG_LAST, nil)
              parser_add_parse_error(token) unless node_html_tag_is(current_node, TAG_FORM)
              until node_html_tag_is(pop_current_node, TAG_FORM)
              end
            else
              node = @form_element
              @form_element = nil
              if !node || !has_node_in_scope(node)
                parser_add_parse_error(token)
                ignore_token
                return
              end
              maybe_flush_text_node_buffer
              generate_implied_end_tags(TAG_LAST, nil)
              parser_add_parse_error(token) unless current_node.equal?(node)
              vector_remove(@open_elements, node)
            end
            return
          end
          if tag == TAG_P
            unless has_an_element_in_button_scope(TAG_P)
              parser_add_parse_error(token)
              insert_element_of_tag_type(TAG_P)
            end
            implicitly_close_tags(token, NAMESPACE_HTML, TAG_P)
            return
          end
          if tag == TAG_LI
            unless has_an_element_in_list_scope(TAG_LI)
              parser_add_parse_error(token)
              ignore_token
              return
            end
            implicitly_close_tags(token, NAMESPACE_HTML, TAG_LI)
            return
          end
          if DD_DT_TAGS[tag] != 0
            unless has_an_element_in_scope(tag)
              parser_add_parse_error(token)
              ignore_token
              return
            end
            implicitly_close_tags(token, NAMESPACE_HTML, tag)
            return
          end
          if HEADING_TAGS[tag] != 0
            unless has_an_element_in_scope_with_tagname(HEADING_TAG_LIST)
              parser_add_parse_error(token)
              ignore_token
              return
            end
            generate_implied_end_tags(TAG_LAST, nil)
            cur = current_node
            parser_add_parse_error(token) unless node_html_tag_is(cur, tag)
            loop do
              cur = pop_current_node
              break if node_tag_in_set(cur, HEADING_TAGS)
            end
            return
          end
          if FORMATTING_END[tag] != 0
            adoption_agency_algorithm(token)
            return
          end
          if APPLET_MARQUEE_OBJECT[tag] != 0
            unless has_an_element_in_scope(tag)
              parser_add_parse_error(token)
              ignore_token
              return
            end
            implicitly_close_tags(token, NAMESPACE_HTML, tag)
            clear_active_formatting_elements
            return
          end
          if tag == TAG_BR
            parser_add_parse_error(token)
            reconstruct_active_formatting_elements
            insert_element_of_tag_type(TAG_BR)
            pop_current_node
            acknowledge_self_closing_tag
            set_frameset_not_ok
            return
          end
          in_body_any_other_end_tag(token)
        end

        def handle_text(token)
          type = token.type
          if type == TOKEN_CHARACTER || type == TOKEN_WHITESPACE
            insert_text_token(token)
            return
          end
          if type == TOKEN_EOF
            parser_add_parse_error(token)
            @reprocess_current_token = true
          end
          pop_current_node
          @insertion_mode = @original_insertion_mode
        end

        def handle_in_table(token)
          type = token.type
          if (type == TOKEN_CHARACTER || type == TOKEN_WHITESPACE || type == TOKEN_NULL) &&
              node_tag_in_set(current_node, IN_TABLE_TEXT_TARGETS)
            @original_insertion_mode = @insertion_mode
            @reprocess_current_token = true
            @insertion_mode = INSERTION_MODE_IN_TABLE_TEXT
            return
          end
          if type == TOKEN_COMMENT
            append_comment_node(current_node, token)
            return
          end
          if type == TOKEN_DOCTYPE
            parser_add_parse_error(token)
            ignore_token
            return
          end
          if start_tag_is(token, TAG_CAPTION)
            clear_stack_to_table_context
            add_formatting_element(MARKER)
            insert_element_from_token(token)
            @insertion_mode = INSERTION_MODE_IN_CAPTION
            return
          end
          if start_tag_is(token, TAG_COLGROUP)
            clear_stack_to_table_context
            insert_element_from_token(token)
            @insertion_mode = INSERTION_MODE_IN_COLUMN_GROUP
            return
          end
          if start_tag_is(token, TAG_COL)
            clear_stack_to_table_context
            insert_element_of_tag_type(TAG_COLGROUP)
            @reprocess_current_token = true
            @insertion_mode = INSERTION_MODE_IN_COLUMN_GROUP
            return
          end
          if start_tag_in(token, TBODY_TFOOT_THEAD)
            clear_stack_to_table_context
            insert_element_from_token(token)
            @insertion_mode = INSERTION_MODE_IN_TABLE_BODY
            return
          end
          if start_tag_in(token, TD_TH_TR)
            clear_stack_to_table_context
            insert_element_of_tag_type(TAG_TBODY)
            @insertion_mode = INSERTION_MODE_IN_TABLE_BODY
            @reprocess_current_token = true
            return
          end
          if start_tag_is(token, TAG_TABLE)
            parser_add_parse_error(token)
            if close_table
              @reprocess_current_token = true
            else
              ignore_token
            end
            return
          end
          if end_tag_is(token, TAG_TABLE)
            parser_add_parse_error(token) unless close_table
            return
          end
          if end_tag_in(token, IN_TABLE_IGNORED_END)
            parser_add_parse_error(token)
            ignore_token
            return
          end
          if start_tag_in(token, STYLE_SCRIPT_TEMPLATE) || end_tag_is(token, TAG_TEMPLATE)
            handle_in_head(token)
            return
          end
          if start_tag_is(token, TAG_INPUT) && attribute_matches(token.attributes, S_TYPE, S_HIDDEN)
            parser_add_parse_error(token)
            insert_element_from_token(token)
            pop_current_node
            acknowledge_self_closing_tag
            return
          end
          if start_tag_is(token, TAG_FORM)
            parser_add_parse_error(token)
            if @form_element || has_open_element(TAG_TEMPLATE)
              ignore_token
              return
            end
            @form_element = insert_element_from_token(token)
            pop_current_node
            return
          end
          if type == TOKEN_EOF
            handle_in_body(token)
            return
          end
          parser_add_parse_error(token)
          @foster_parent_insertions = true
          handle_in_body(token)
          @foster_parent_insertions = false
        end

        def handle_in_table_text(token)
          type = token.type
          if type == TOKEN_NULL
            parser_add_parse_error(token)
            ignore_token
            return
          end
          if type == TOKEN_WHITESPACE || type == TOKEN_CHARACTER
            insert_text_token(token)
            @table_character_tokens << [token.line, token.column, token.offset, token.orig_start,
                                        token.orig_len, token.character,]
            return
          end

          buffer = @table_character_tokens
          if @text_type != NODE_WHITESPACE
            tok = Token.new
            buffer.each do |line, column, offset, orig_start, orig_len, c|
              tok.type = Util.ascii_isspace(c) ? TOKEN_WHITESPACE : TOKEN_CHARACTER
              tok.line = line
              tok.column = column
              tok.offset = offset
              tok.orig_start = orig_start
              tok.orig_len = orig_len
              tok.character = c
              parser_add_parse_error(tok)
            end
            @foster_parent_insertions = true
            set_frameset_not_ok
            reconstruct_active_formatting_elements
          end
          maybe_flush_text_node_buffer
          buffer.clear
          @foster_parent_insertions = false
          @reprocess_current_token = true
          @insertion_mode = @original_insertion_mode
        end

        def handle_in_caption(token)
          if end_tag_is(token, TAG_CAPTION)
            unless has_an_element_in_table_scope(TAG_CAPTION)
              parser_add_parse_error(token)
              ignore_token
              return
            end
            generate_implied_end_tags(TAG_LAST, nil)
            parser_add_parse_error(token) unless node_html_tag_is(current_node, TAG_CAPTION)
            until node_html_tag_is(pop_current_node, TAG_CAPTION)
            end
            clear_active_formatting_elements
            @insertion_mode = INSERTION_MODE_IN_TABLE
            return
          end
          if start_tag_in(token, IN_CAPTION_CLOSE_START) || end_tag_is(token, TAG_TABLE)
            unless has_an_element_in_table_scope(TAG_CAPTION)
              parser_add_parse_error(token)
              ignore_token
              return
            end
            generate_implied_end_tags(TAG_LAST, nil)
            parser_add_parse_error(token) unless node_html_tag_is(current_node, TAG_CAPTION)
            until node_html_tag_is(pop_current_node, TAG_CAPTION)
            end
            clear_active_formatting_elements
            @insertion_mode = INSERTION_MODE_IN_TABLE
            @reprocess_current_token = true
            return
          end
          if end_tag_in(token, IN_CAPTION_IGNORED_END)
            parser_add_parse_error(token)
            ignore_token
            return
          end
          handle_in_body(token)
        end

        def handle_in_column_group(token)
          type = token.type
          if type == TOKEN_WHITESPACE
            insert_text_token(token)
            return
          end
          if type == TOKEN_COMMENT
            append_comment_node(current_node, token)
            return
          end
          if type == TOKEN_DOCTYPE
            parser_add_parse_error(token)
            ignore_token
            return
          end
          if start_tag_is(token, TAG_HTML)
            handle_in_body(token)
            return
          end
          if start_tag_is(token, TAG_COL)
            insert_element_from_token(token)
            pop_current_node
            acknowledge_self_closing_tag
            return
          end
          if end_tag_is(token, TAG_COLGROUP)
            unless node_html_tag_is(current_node, TAG_COLGROUP)
              parser_add_parse_error(token)
              ignore_token
              return
            end
            pop_current_node
            @insertion_mode = INSERTION_MODE_IN_TABLE
            return
          end
          if end_tag_is(token, TAG_COL)
            parser_add_parse_error(token)
            ignore_token
            return
          end
          if start_tag_is(token, TAG_TEMPLATE) || end_tag_is(token, TAG_TEMPLATE)
            handle_in_head(token)
            return
          end
          if type == TOKEN_EOF
            handle_in_body(token)
            return
          end
          unless node_html_tag_is(current_node, TAG_COLGROUP)
            parser_add_parse_error(token)
            ignore_token
            return
          end
          pop_current_node
          @insertion_mode = INSERTION_MODE_IN_TABLE
          @reprocess_current_token = true
        end

        def handle_in_table_body(token)
          if start_tag_is(token, TAG_TR)
            clear_stack_to_table_body_context
            insert_element_from_token(token)
            @insertion_mode = INSERTION_MODE_IN_ROW
            return
          end
          if start_tag_in(token, TD_TH_TAGS)
            parser_add_parse_error(token)
            clear_stack_to_table_body_context
            insert_element_of_tag_type(TAG_TR)
            @insertion_mode = INSERTION_MODE_IN_ROW
            @reprocess_current_token = true
            return
          end
          if end_tag_in(token, TBODY_TFOOT_THEAD)
            unless has_an_element_in_table_scope(token.tag)
              parser_add_parse_error(token)
              ignore_token
              return
            end
            clear_stack_to_table_body_context
            pop_current_node
            @insertion_mode = INSERTION_MODE_IN_TABLE
            return
          end
          if start_tag_in(token, IN_TABLE_BODY_CLOSE_START) || end_tag_is(token, TAG_TABLE)
            unless has_an_element_in_table_scope(TAG_TBODY) || has_an_element_in_table_scope(TAG_THEAD) ||
                has_an_element_in_table_scope(TAG_TFOOT)
              parser_add_parse_error(token)
              ignore_token
              return
            end
            clear_stack_to_table_body_context
            pop_current_node
            @insertion_mode = INSERTION_MODE_IN_TABLE
            @reprocess_current_token = true
            return
          end
          if end_tag_in(token, IN_TABLE_BODY_IGNORED_END)
            parser_add_parse_error(token)
            ignore_token
            return
          end
          handle_in_table(token)
        end

        def handle_in_row(token)
          if start_tag_in(token, TD_TH_TAGS)
            clear_stack_to_table_row_context
            insert_element_from_token(token)
            @insertion_mode = INSERTION_MODE_IN_CELL
            add_formatting_element(MARKER)
            return
          end
          if end_tag_is(token, TAG_TR)
            unless has_an_element_in_table_scope(TAG_TR)
              parser_add_parse_error(token)
              ignore_token
              return
            end
            clear_stack_to_table_row_context
            pop_current_node
            @insertion_mode = INSERTION_MODE_IN_TABLE_BODY
            return
          end
          if start_tag_in(token, IN_ROW_CLOSE_START) || end_tag_is(token, TAG_TABLE)
            unless has_an_element_in_table_scope(TAG_TR)
              parser_add_parse_error(token)
              ignore_token
              return
            end
            clear_stack_to_table_row_context
            pop_current_node
            @insertion_mode = INSERTION_MODE_IN_TABLE_BODY
            @reprocess_current_token = true
            return
          end
          if end_tag_in(token, TBODY_TFOOT_THEAD)
            unless has_an_element_in_table_scope(token.tag)
              parser_add_parse_error(token)
              ignore_token
              return
            end
            unless has_an_element_in_table_scope(TAG_TR)
              ignore_token
              return
            end
            clear_stack_to_table_row_context
            pop_current_node
            @insertion_mode = INSERTION_MODE_IN_TABLE_BODY
            @reprocess_current_token = true
            return
          end
          if end_tag_in(token, IN_ROW_IGNORED_END)
            parser_add_parse_error(token)
            ignore_token
            return
          end
          handle_in_table(token)
        end

        def handle_in_cell(token)
          if end_tag_in(token, TD_TH_TAGS)
            token_tag = token.tag
            unless has_an_element_in_table_scope(token_tag)
              parser_add_parse_error(token)
              ignore_token
              return
            end
            close_table_cell(token, token_tag)
            return
          end
          if start_tag_in(token, IN_CAPTION_CLOSE_START)
            if !has_an_element_in_table_scope(TAG_TH) && !has_an_element_in_table_scope(TAG_TD)
              parser_add_parse_error(token)
              ignore_token
              return
            end
            @reprocess_current_token = true
            close_current_cell(token)
            return
          end
          if end_tag_in(token, IN_CELL_IGNORED_END)
            parser_add_parse_error(token)
            ignore_token
            return
          end
          if end_tag_in(token, IN_CELL_CLOSE_END)
            unless has_an_element_in_table_scope(token.tag)
              parser_add_parse_error(token)
              ignore_token
              return
            end
            @reprocess_current_token = true
            close_current_cell(token)
            return
          end
          handle_in_body(token)
        end

        def handle_in_select(token)
          type = token.type
          if type == TOKEN_NULL
            parser_add_parse_error(token)
            ignore_token
            return
          end
          if type == TOKEN_CHARACTER || type == TOKEN_WHITESPACE
            insert_text_token(token)
            return
          end
          if type == TOKEN_COMMENT
            append_comment_node(current_node, token)
            return
          end
          if type == TOKEN_DOCTYPE
            parser_add_parse_error(token)
            ignore_token
            return
          end
          if start_tag_is(token, TAG_HTML)
            handle_in_body(token)
            return
          end
          if start_tag_is(token, TAG_OPTION)
            pop_current_node if node_html_tag_is(current_node, TAG_OPTION)
            insert_element_from_token(token)
            return
          end
          if start_tag_is(token, TAG_OPTGROUP)
            pop_current_node if node_html_tag_is(current_node, TAG_OPTION)
            pop_current_node if node_html_tag_is(current_node, TAG_OPTGROUP)
            insert_element_from_token(token)
            return
          end
          if start_tag_is(token, TAG_HR)
            pop_current_node if node_html_tag_is(current_node, TAG_OPTION)
            pop_current_node if node_html_tag_is(current_node, TAG_OPTGROUP)
            insert_element_from_token(token)
            pop_current_node
            acknowledge_self_closing_tag
            return
          end
          if end_tag_is(token, TAG_OPTGROUP)
            open_elements = @open_elements
            if node_html_tag_is(current_node, TAG_OPTION) &&
                node_html_tag_is(open_elements[open_elements.length - 2], TAG_OPTGROUP)
              pop_current_node
            end
            if node_html_tag_is(current_node, TAG_OPTGROUP)
              pop_current_node
              return
            end
            parser_add_parse_error(token)
            ignore_token
            return
          end
          if end_tag_is(token, TAG_OPTION)
            if node_html_tag_is(current_node, TAG_OPTION)
              pop_current_node
              return
            end
            parser_add_parse_error(token)
            ignore_token
            return
          end
          if end_tag_is(token, TAG_SELECT)
            unless has_an_element_in_select_scope(TAG_SELECT)
              parser_add_parse_error(token)
              ignore_token
              return
            end
            close_current_select
            return
          end
          if start_tag_is(token, TAG_SELECT)
            parser_add_parse_error(token)
            ignore_token
            close_current_select if has_an_element_in_select_scope(TAG_SELECT)
            return
          end
          if start_tag_in(token, INPUT_KEYGEN_TEXTAREA)
            parser_add_parse_error(token)
            if !has_an_element_in_select_scope(TAG_SELECT)
              ignore_token
            else
              close_current_select
              @reprocess_current_token = true
            end
            return
          end
          if start_tag_in(token, SCRIPT_TEMPLATE) || end_tag_is(token, TAG_TEMPLATE)
            handle_in_head(token)
            return
          end
          if type == TOKEN_EOF
            handle_in_body(token)
            return
          end
          parser_add_parse_error(token)
          ignore_token
        end

        def handle_in_select_in_table(token)
          if start_tag_in(token, SELECT_IN_TABLE_TAGS)
            parser_add_parse_error(token)
            close_current_select
            @reprocess_current_token = true
            return
          end
          if end_tag_in(token, SELECT_IN_TABLE_TAGS)
            parser_add_parse_error(token)
            unless has_an_element_in_table_scope(token.tag)
              ignore_token
              return
            end
            close_current_select
            @reprocess_current_token = true
            return
          end
          handle_in_select(token)
        end

        def handle_in_template(token)
          case token.type
          when TOKEN_WHITESPACE, TOKEN_CHARACTER, TOKEN_COMMENT, TOKEN_NULL, TOKEN_DOCTYPE
            handle_in_body(token)
            return
          end
          if start_tag_in(token, IN_TEMPLATE_HEAD_TAGS) || end_tag_is(token, TAG_TEMPLATE)
            handle_in_head(token)
            return
          end
          if start_tag_in(token, IN_TEMPLATE_TABLE_TAGS)
            pop_template_insertion_mode
            push_template_insertion_mode(INSERTION_MODE_IN_TABLE)
            @insertion_mode = INSERTION_MODE_IN_TABLE
            @reprocess_current_token = true
            return
          end
          if start_tag_is(token, TAG_COL)
            pop_template_insertion_mode
            push_template_insertion_mode(INSERTION_MODE_IN_COLUMN_GROUP)
            @insertion_mode = INSERTION_MODE_IN_COLUMN_GROUP
            @reprocess_current_token = true
            return
          end
          if start_tag_is(token, TAG_TR)
            pop_template_insertion_mode
            push_template_insertion_mode(INSERTION_MODE_IN_TABLE_BODY)
            @insertion_mode = INSERTION_MODE_IN_TABLE_BODY
            @reprocess_current_token = true
            return
          end
          if start_tag_in(token, TD_TH_TAGS)
            pop_template_insertion_mode
            push_template_insertion_mode(INSERTION_MODE_IN_ROW)
            @insertion_mode = INSERTION_MODE_IN_ROW
            @reprocess_current_token = true
            return
          end
          if token.type == TOKEN_START_TAG
            pop_template_insertion_mode
            push_template_insertion_mode(INSERTION_MODE_IN_BODY)
            @insertion_mode = INSERTION_MODE_IN_BODY
            @reprocess_current_token = true
            return
          end
          if token.type == TOKEN_END_TAG
            parser_add_parse_error(token)
            ignore_token
            return
          end
          if token.type == TOKEN_EOF
            return unless has_open_element(TAG_TEMPLATE)

            parser_add_parse_error(token)
            until node_html_tag_is(pop_current_node, TAG_TEMPLATE)
            end
            clear_active_formatting_elements
            pop_template_insertion_mode
            reset_insertion_mode_appropriately
            @reprocess_current_token = true
          end
        end

        def handle_after_body(token)
          type = token.type
          if type == TOKEN_WHITESPACE || start_tag_is(token, TAG_HTML)
            handle_in_body(token)
            return
          end
          if type == TOKEN_COMMENT
            append_comment_node(@output.root, token)
            return
          end
          if type == TOKEN_DOCTYPE
            parser_add_parse_error(token)
            ignore_token
            return
          end
          if end_tag_is(token, TAG_HTML)
            if is_fragment_parser
              parser_add_parse_error(token)
              ignore_token
              return
            end
            @insertion_mode = INSERTION_MODE_AFTER_AFTER_BODY
            return
          end
          return if type == TOKEN_EOF

          parser_add_parse_error(token)
          @insertion_mode = INSERTION_MODE_IN_BODY
          @reprocess_current_token = true
        end

        def handle_in_frameset(token)
          type = token.type
          if type == TOKEN_WHITESPACE
            insert_text_token(token)
            return
          end
          if type == TOKEN_COMMENT
            append_comment_node(current_node, token)
            return
          end
          if type == TOKEN_DOCTYPE
            parser_add_parse_error(token)
            ignore_token
            return
          end
          if start_tag_is(token, TAG_HTML)
            handle_in_body(token)
            return
          end
          if start_tag_is(token, TAG_FRAMESET)
            insert_element_from_token(token)
            return
          end
          if end_tag_is(token, TAG_FRAMESET)
            if node_html_tag_is(current_node, TAG_HTML)
              parser_add_parse_error(token)
              ignore_token
              return
            end
            pop_current_node
            if !is_fragment_parser && !node_html_tag_is(current_node, TAG_FRAMESET)
              @insertion_mode = INSERTION_MODE_AFTER_FRAMESET
            end
            return
          end
          if start_tag_is(token, TAG_FRAME)
            insert_element_from_token(token)
            pop_current_node
            acknowledge_self_closing_tag
            return
          end
          if start_tag_is(token, TAG_NOFRAMES)
            handle_in_head(token)
            return
          end
          if type == TOKEN_EOF
            parser_add_parse_error(token) unless node_html_tag_is(current_node, TAG_HTML)
            return
          end
          parser_add_parse_error(token)
          ignore_token
        end

        def handle_after_frameset(token)
          type = token.type
          if type == TOKEN_WHITESPACE
            insert_text_token(token)
            return
          end
          if type == TOKEN_COMMENT
            append_comment_node(current_node, token)
            return
          end
          if type == TOKEN_DOCTYPE
            parser_add_parse_error(token)
            ignore_token
            return
          end
          if start_tag_is(token, TAG_HTML)
            handle_in_body(token)
            return
          end
          if end_tag_is(token, TAG_HTML)
            @insertion_mode = INSERTION_MODE_AFTER_AFTER_FRAMESET
            return
          end
          if start_tag_is(token, TAG_NOFRAMES)
            handle_in_head(token)
            return
          end
          return if type == TOKEN_EOF

          parser_add_parse_error(token)
          ignore_token
        end

        def handle_after_after_body(token)
          type = token.type
          if type == TOKEN_COMMENT
            append_comment_node(document_node, token)
            return
          end
          if type == TOKEN_DOCTYPE || type == TOKEN_WHITESPACE || start_tag_is(token, TAG_HTML)
            handle_in_body(token)
            return
          end
          return if type == TOKEN_EOF

          parser_add_parse_error(token)
          @insertion_mode = INSERTION_MODE_IN_BODY
          @reprocess_current_token = true
        end

        def handle_after_after_frameset(token)
          type = token.type
          if type == TOKEN_COMMENT
            append_comment_node(document_node, token)
            return
          end
          if type == TOKEN_DOCTYPE || type == TOKEN_WHITESPACE || start_tag_is(token, TAG_HTML)
            handle_in_body(token)
            return
          end
          return if type == TOKEN_EOF

          if start_tag_is(token, TAG_NOFRAMES)
            handle_in_head(token)
            return
          end
          parser_add_parse_error(token)
          ignore_token
        end

        TOKEN_HANDLERS = [
          :handle_initial,
          :handle_before_html,
          :handle_before_head,
          :handle_in_head,
          :handle_in_head_noscript,
          :handle_after_head,
          :handle_in_body,
          :handle_text,
          :handle_in_table,
          :handle_in_table_text,
          :handle_in_caption,
          :handle_in_column_group,
          :handle_in_table_body,
          :handle_in_row,
          :handle_in_cell,
          :handle_in_select,
          :handle_in_select_in_table,
          :handle_in_template,
          :handle_after_body,
          :handle_in_frameset,
          :handle_after_frameset,
          :handle_after_after_body,
          :handle_after_after_frameset,
        ].freeze

        def handle_html_content(token)
          __send__(TOKEN_HANDLERS[@insertion_mode], token)
        end

        def handle_in_foreign_content(token)
          case token.type
          when TOKEN_NULL
            parser_add_parse_error(token)
            token.character = REPLACEMENT_CHAR
            insert_text_token(token)
            return
          when TOKEN_WHITESPACE
            insert_text_token(token)
            return
          when TOKEN_CDATA, TOKEN_CHARACTER
            insert_text_token(token)
            set_frameset_not_ok
            return
          when TOKEN_COMMENT
            append_comment_node(current_node, token)
            return
          when TOKEN_DOCTYPE
            parser_add_parse_error(token)
            ignore_token
            return
          end

          if start_tag_in(token, FOREIGN_BREAKOUT_START) ||
              (start_tag_is(token, TAG_FONT) &&
                (token_has_attribute(token, S_COLOR) || token_has_attribute(token, S_FACE) ||
                  token_has_attribute(token, S_SIZE))) ||
              end_tag_in(token, BR_P)
            parser_add_parse_error(token)
            until is_mathml_integration_point(current_node) || is_html_integration_point(current_node) ||
                current_node.tag_namespace == NAMESPACE_HTML
              pop_current_node
            end
            handle_html_content(token)
            return
          end

          if token.type == TOKEN_START_TAG
            current_namespace = adjusted_current_node.tag_namespace
            adjust_mathml_attributes(token) if current_namespace == NAMESPACE_MATHML
            if current_namespace == NAMESPACE_SVG
              adjust_svg_tag(token)
              adjust_svg_attributes(token)
            end
            adjust_foreign_attributes(token)
            insert_foreign_element(token, current_namespace)
            if token.is_self_closing
              pop_current_node
              acknowledge_self_closing_tag
            end
            return
          end

          node = current_node
          tag = token.tag
          name = token.name
          parser_add_parse_error(token) unless node_tagname_is(node, tag, name)
          i = @open_elements.length - 1
          while i > 0
            if node_tagname_is(node, tag, name)
              until node.equal?(pop_current_node)
              end
              return
            end
            i -= 1
            node = @open_elements[i]
            break if node.tag_namespace == NAMESPACE_HTML
          end
          return if i == 0

          handle_html_content(token)
        end

        def handle_token(token)
          if @ignore_next_linefeed && token.type == TOKEN_WHITESPACE && token.character == 0x0a
            @ignore_next_linefeed = false
            ignore_token
            return
          end
          @ignore_next_linefeed = false

          if token.type == TOKEN_END_TAG
            @closed_body_tag = true if token.tag == TAG_BODY
            @closed_html_tag = true if token.tag == TAG_HTML
          end

          node = adjusted_current_node
          type = token.type
          if node.nil? || node.tag_namespace == NAMESPACE_HTML ||
              (is_mathml_integration_point(node) &&
                (type == TOKEN_CHARACTER || type == TOKEN_WHITESPACE || type == TOKEN_NULL ||
                  (type == TOKEN_START_TAG && !start_tag_in(token, MGLYPH_MALIGNMARK)))) ||
              (node.tag_namespace == NAMESPACE_MATHML &&
                node_qualified_tag_is(node, NAMESPACE_MATHML, TAG_ANNOTATION_XML) &&
                start_tag_is(token, TAG_SVG)) ||
              (is_html_integration_point(node) &&
                (type == TOKEN_START_TAG || type == TOKEN_CHARACTER || type == TOKEN_NULL ||
                  type == TOKEN_WHITESPACE)) ||
              type == TOKEN_EOF
            handle_html_content(token)
          else
            handle_in_foreign_content(token)
          end
        end

        def create_fragment_ctx_element(tag_name, ns, encoding)
          tag = Util.tagn_enum(tag_name)
          type = ns == NAMESPACE_HTML && tag == TAG_TEMPLATE ? NODE_TEMPLATE : NODE_ELEMENT
          node = Node.new(type)
          node.children = []
          node.attributes = []
          if encoding
            node.attributes << Attribute.new(S_ENCODING, encoding, 0)
          end
          node.tag = tag
          node.tag_namespace = ns
          node.name = tag_name
          node
        end

        def fragment_parser_init(options)
          fragment_ctx = options.fragment_context.b
          fragment_namespace = options.fragment_namespace
          fragment_encoding = options.fragment_encoding&.b
          quirks = options.quirks_mode
          ctx_has_form_ancestor = options.fragment_context_has_form_ancestor

          document_node.doc_type_quirks_mode = quirks
          @fragment_ctx = create_fragment_ctx_element(fragment_ctx, fragment_namespace, fragment_encoding)
          ctx_tag = @fragment_ctx.tag

          if fragment_namespace == NAMESPACE_HTML
            case ctx_tag
            when TAG_TITLE, TAG_TEXTAREA
              @tokenizer.set_state(LEX_RCDATA)
            when TAG_STYLE, TAG_XMP, TAG_IFRAME, TAG_NOEMBED, TAG_NOFRAMES
              @tokenizer.set_state(LEX_RAWTEXT)
            when TAG_SCRIPT
              @tokenizer.set_state(LEX_SCRIPT_DATA)
            when TAG_NOSCRIPT
              @tokenizer.set_state(LEX_RAWTEXT) if options.parse_noscript_content_as_text
            when TAG_PLAINTEXT
              @tokenizer.set_state(LEX_PLAINTEXT)
            end
          end

          root = insert_element_of_tag_type(TAG_HTML)
          @output.root = root

          push_template_insertion_mode(INSERTION_MODE_IN_TEMPLATE) if ctx_tag == TAG_TEMPLATE

          reset_insertion_mode_appropriately

          if ctx_has_form_ancestor || (ctx_tag == TAG_FORM && fragment_namespace == NAMESPACE_HTML)
            @form_element = FORM_ANCESTOR
          end
        end

        # Fast path (not in gumbo): consume a run of plain character tokens at once when each of
        # them would just be appended to the pending text node. `acn` is the adjusted current
        # node. Equivalent to handling the tokens one by one: the first one would reconstruct the
        # active formatting elements (making the reconstruction a no-op for the others), and
        # none of them can produce an error or change the insertion mode.
        def bulk_text(acn)
          html_path = acn.nil? || acn.tag_namespace == NAMESPACE_HTML ||
            is_mathml_integration_point(acn) || is_html_integration_point(acn)
          if html_path
            case @insertion_mode
            when INSERTION_MODE_IN_BODY, INSERTION_MODE_IN_CELL, INSERTION_MODE_IN_CAPTION,
              INSERTION_MODE_IN_TEMPLATE
              body_like = true
            when INSERTION_MODE_TEXT, INSERTION_MODE_IN_SELECT, INSERTION_MODE_IN_SELECT_IN_TABLE
              body_like = false
            else
              return
            end
          end
          start_line = @tokenizer.line
          run = @tokenizer.scan_text_run
          return unless run

          reconstruct_active_formatting_elements if body_like
          buffer = @text_buffer
          @text_start_line = start_line if buffer.empty?
          buffer << run
          if run.match?(Tokenizer::NON_WS_RE)
            @text_type = NODE_TEXT
            @frameset_ok = false if body_like || !html_path
          end
          true
        end

        # the main loop of gumbo_parse_with_options
        def run
          options = @options
          fragment_parser_init(options) if options.fragment_context

          max_tree_depth = options.max_tree_depth
          token = Token.new
          tokenizer = @tokenizer
          open_elements = @open_elements
          stop_on_first_error = options.stop_on_first_error

          loop do
            if @reprocess_current_token
              @reprocess_current_token = false
            else
              acn = adjusted_current_node
              tokenizer.set_is_adjusted_current_node_foreign(!acn.nil? && acn.tag_namespace != NAMESPACE_HTML)
              if !@ignore_next_linefeed && open_elements.length <= max_tree_depth && bulk_text(acn)
                # the text run stood for character tokens handled one per iteration: the next token
                # starts a new iteration (the run may have reconstructed formatting elements)
                acn = adjusted_current_node
                tokenizer.set_is_adjusted_current_node_foreign(!acn.nil? && acn.tag_namespace != NAMESPACE_HTML)
              end
              if open_elements.length > max_tree_depth
                @output.status = STATUS_TREE_TOO_DEEP
                token.type = TOKEN_EOF
              else
                tokenizer.lex(token)
              end
            end

            @current_token = token
            @self_closing_flag_acknowledged = false

            handle_token(token)

            if !@reprocess_current_token && token.type == TOKEN_START_TAG && token.is_self_closing &&
                !@self_closing_flag_acknowledged
              error = add_error
              if error
                error.type = ERR_NON_VOID_HTML_ELEMENT_START_TAG_WITH_TRAILING_SOLIDUS
                error.orig_start = token.orig_start
                error.orig_len = token.orig_len
                error.line = token.line
                error.column = token.column
                error.offset = token.offset
              end
            end

            break unless (token.type != TOKEN_EOF || @reprocess_current_token) &&
              !(stop_on_first_error && @output.document_error)
          end

          finish_parsing
          doc = @output.document
          doc.doc_name ||= S_EMPTY.dup
          doc.public_identifier ||= S_EMPTY.dup
          doc.system_identifier ||= S_EMPTY.dup
          @output
        end
      end

      def compute_quirks_mode(name, pubid, sysid)
        Parser.compute_quirks_mode(name, pubid, sysid)
      end
    end
  end
end
