# frozen_string_literal: true

# Port of gumbo-parser's error.c: error records, messages and caret diagnostics.

module Nokogiri
  module Pure
    module Gumbo
      # GumboError. Tokenizer errors use codepoint/state, parser errors use the input_* fields.
      class Error
        attr_accessor :type, :line, :column, :offset, :orig_start, :orig_len,
          :codepoint, :state,
          :input_type, :input_tag, :input_name, :parser_state, :tag_stack

        def initialize
          @type = ERR_PARSER
          @line = 0
          @column = 0
          @offset = 0
          @orig_start = 0
          @orig_len = 0
          @codepoint = 0
          @state = nil
        end

        CODES = [
          "abrupt-closing-of-empty-comment",
          "abrupt-doctype-public-identifier",
          "abrupt-doctype-system-identifier",
          "absence-of-digits-in-numeric-character-reference",
          "cdata-in-html-content",
          "character-reference-outside-unicode-range",
          "control-character-in-input-stream",
          "control-character-reference",
          "end-tag-with-attributes",
          "duplicate-attribute",
          "end-tag-with-trailing-solidus",
          "eof-before-tag-name",
          "eof-in-cdata",
          "eof-in-comment",
          "eof-in-doctype",
          "eof-in-script-html-comment-like-text",
          "eof-in-tag",
          "incorrectly-closed-comment",
          "incorrectly-opened-comment",
          "invalid-character-sequence-after-doctype-name",
          "invalid-first-character-of-tag-name",
          "missing-attribute-value",
          "missing-doctype-name",
          "missing-doctype-public-identifier",
          "missing-doctype-system-identifier",
          "missing-end-tag-name",
          "missing-quote-before-doctype-public-identifier",
          "missing-quote-before-doctype-system-identifier",
          "missing-semicolon-after-character-reference",
          "missing-whitespace-after-doctype-public-keyword",
          "missing-whitespace-after-doctype-system-keyword",
          "missing-whitespace-before-doctype-name",
          "missing-whitespace-between-attributes",
          "missing-whitespace-between-doctype-public-and-system-identifiers",
          "nested-comment",
          "noncharacter-character-reference",
          "noncharacter-in-input-stream",
          "non-void-html-element-start-tag-with-trailing-solidus",
          "null-character-reference",
          "surrogate-character-reference",
          "surrogate-in-input-stream",
          "unexpected-character-after-doctype-system-identifier",
          "unexpected-character-in-attribute-name",
          "unexpected-character-in-unquoted-attribute-value",
          "unexpected-equals-sign-before-attribute-name",
          "unexpected-null-character",
          "unexpected-question-mark-instead-of-tag-name",
          "unexpected-solidus-in-tag",
          "unknown-named-character-reference",
          "utf8-invalid",
          "utf8-truncated",
          "generic-parser",
        ].map { |s| s.b.freeze }.freeze

        # gumbo_error_code
        def code
          CODES[@type] || "generic-parser"
        end

        # gumbo_caret_diagnostic_to_string: returns a binary String.
        def caret_diagnostic(source)
          out = String.new(encoding: Encoding::BINARY)
          to_s_into(out, source)
          error_text = @orig_start
          line_start = find_prev_newline(source, error_text)
          line_end = find_next_newline(source, error_text)
          out << 0x0a
          out << source.byteslice(line_start, line_end - line_start)
          out << 0x0a
          out << (" " * (@column - 1)) if @column >= 2
          out << "^\n"
          out
        end

        private

        # "%.*s" of the original text: stops at the first NUL byte, like printf does.
        def original_text(source)
          s = source.byteslice(@orig_start, @orig_len) || String.new(encoding: Encoding::BINARY)
          i = s.index("\0")
          i ? s.byteslice(0, i) : s
        end

        # "%c" of an int: the low byte
        def char_c(cp)
          (cp & 0xff).chr(Encoding::BINARY)
        end

        def hex04(cp)
          format("%04X", cp)
        end

        def to_s_into(out, source)
          if @type < ERR_PARSER
            tokenizer_message(out, source)
          else
            parser_message(out)
          end
        end

        def tokenizer_message(out, source)
          msg = case @type
          when ERR_ABRUPT_CLOSING_OF_EMPTY_COMMENT
            "Empty comment abruptly closed by '#{@state == LEX_COMMENT_START ? ">" : "->"}', use '-->'."
          when ERR_ABRUPT_DOCTYPE_PUBLIC_IDENTIFIER
            q = @state == LEX_DOCTYPE_PUBLIC_ID_DOUBLE_QUOTED ? "quotation mark (\")" : "apostrophe (')"
            "DOCTYPE public identifier missing closing #{q}."
          when ERR_ABRUPT_DOCTYPE_SYSTEM_IDENTIFIER
            q = @state == LEX_DOCTYPE_SYSTEM_ID_DOUBLE_QUOTED ? "quotation mark (\")" : "apostrophe (')"
            "DOCTYPE system identifier missing closing #{q}."
          when ERR_ABSENCE_OF_DIGITS_IN_NUMERIC_CHARACTER_REFERENCE
            hex = @state == LEX_HEXADECIMAL_CHARACTER_REFERENCE_START ? "hexadecimal " : ""
            "Numeric character reference '".b + original_text(source) + "' does not contain any #{hex}digits."
          when ERR_CDATA_IN_HTML_CONTENT
            "CDATA section outside foreign (SVG or MathML) content."
          when ERR_CHARACTER_REFERENCE_OUTSIDE_UNICODE_RANGE
            "Numeric character reference '".b + original_text(source) +
              "' references a code point that is outside the valid Unicode range."
          when ERR_CONTROL_CHARACTER_IN_INPUT_STREAM
            "Input contains prohibited control code point U+#{hex04(@codepoint)}."
          when ERR_CONTROL_CHARACTER_REFERENCE
            "Numeric character reference '".b + original_text(source) +
              "' references prohibited control code point U+#{hex04(@codepoint)}."
          when ERR_END_TAG_WITH_ATTRIBUTES
            "End tag contains attributes."
          when ERR_DUPLICATE_ATTRIBUTE
            "Tag contains multiple attributes with the same name."
          when ERR_END_TAG_WITH_TRAILING_SOLIDUS
            "End tag ends with '/>', use '>'."
          when ERR_EOF_BEFORE_TAG_NAME
            "End of input where a tag name is expected."
          when ERR_EOF_IN_CDATA
            "End of input in CDATA section."
          when ERR_EOF_IN_COMMENT
            "End of input in comment."
          when ERR_EOF_IN_DOCTYPE
            "End of input in DOCTYPE."
          when ERR_EOF_IN_SCRIPT_HTML_COMMENT_LIKE_TEXT
            "End of input in text that resembles an HTML comment inside script element content."
          when ERR_EOF_IN_TAG
            "End of input in tag."
          when ERR_INCORRECTLY_CLOSED_COMMENT
            "Comment closed incorrectly by '--!>', use '-->'."
          when ERR_INCORRECTLY_OPENED_COMMENT
            "Comment, DOCTYPE, or CDATA opened incorrectly, use '<!--', '<!DOCTYPE', or '<![CDATA['."
          when ERR_INVALID_CHARACTER_SEQUENCE_AFTER_DOCTYPE_NAME
            "Invalid character sequence after DOCTYPE name, expected 'PUBLIC', 'SYSTEM', or '>'."
          when ERR_INVALID_FIRST_CHARACTER_OF_TAG_NAME
            cp = @codepoint
            if cp >= 0 && cp < 0x80 && !ASCII_CNTRL[cp]
              "Invalid first character of tag name '".b + char_c(cp) + "'."
            else
              "Invalid first code point of tag name U+#{hex04(cp)}."
            end
          when ERR_MISSING_ATTRIBUTE_VALUE
            "Missing attribute value."
          when ERR_MISSING_DOCTYPE_NAME
            "Missing DOCTYPE name."
          when ERR_MISSING_DOCTYPE_PUBLIC_IDENTIFIER
            "Missing DOCTYPE public identifier."
          when ERR_MISSING_DOCTYPE_SYSTEM_IDENTIFIER
            "Missing DOCTYPE system identifier."
          when ERR_MISSING_END_TAG_NAME
            "Missing end tag name."
          when ERR_MISSING_QUOTE_BEFORE_DOCTYPE_PUBLIC_IDENTIFIER
            "Missing quote before DOCTYPE public identifier."
          when ERR_MISSING_QUOTE_BEFORE_DOCTYPE_SYSTEM_IDENTIFIER
            "Missing quote before DOCTYPE system identifier."
          when ERR_MISSING_SEMICOLON_AFTER_CHARACTER_REFERENCE
            "Missing semicolon after character reference '".b + original_text(source) + "'."
          when ERR_MISSING_WHITESPACE_AFTER_DOCTYPE_PUBLIC_KEYWORD
            "Missing whitespace after 'PUBLIC' keyword."
          when ERR_MISSING_WHITESPACE_AFTER_DOCTYPE_SYSTEM_KEYWORD
            "Missing whitespace after 'SYSTEM' keyword."
          when ERR_MISSING_WHITESPACE_BEFORE_DOCTYPE_NAME
            "Missing whitespace between 'DOCTYPE' keyword and DOCTYPE name."
          when ERR_MISSING_WHITESPACE_BETWEEN_ATTRIBUTES
            "Missing whitespace between attributes."
          when ERR_MISSING_WHITESPACE_BETWEEN_DOCTYPE_PUBLIC_AND_SYSTEM_IDENTIFIERS
            "Missing whitespace between DOCTYPE public and system identifiers."
          when ERR_NESTED_COMMENT
            "Nested comment."
          when ERR_NONCHARACTER_CHARACTER_REFERENCE
            "Numeric character reference '".b + original_text(source) +
              "' references noncharacter U+#{hex04(@codepoint)}."
          when ERR_NONCHARACTER_IN_INPUT_STREAM
            "Input contains noncharacter U+#{hex04(@codepoint)}."
          when ERR_NON_VOID_HTML_ELEMENT_START_TAG_WITH_TRAILING_SOLIDUS
            "Start tag of nonvoid HTML element ends with '/>', use '>'."
          when ERR_NULL_CHARACTER_REFERENCE
            "Numeric character reference '".b + original_text(source) + "' references U+0000."
          when ERR_SURROGATE_CHARACTER_REFERENCE
            "Numeric character reference '".b + original_text(source) +
              "' references surrogate U+#{format("%4X", @codepoint)}."
          when ERR_SURROGATE_IN_INPUT_STREAM
            "Input contains surrogate U+#{hex04(@codepoint)}."
          when ERR_UNEXPECTED_CHARACTER_AFTER_DOCTYPE_SYSTEM_IDENTIFIER
            "Unexpected character after DOCTYPE system identifier."
          when ERR_UNEXPECTED_CHARACTER_IN_ATTRIBUTE_NAME
            "Unexpected character (".b + char_c(@codepoint) + ") in attribute name."
          when ERR_UNEXPECTED_CHARACTER_IN_UNQUOTED_ATTRIBUTE_VALUE
            "Unexpected character (".b + char_c(@codepoint) + ") in unquoted attribute value."
          when ERR_UNEXPECTED_EQUALS_SIGN_BEFORE_ATTRIBUTE_NAME
            "Unexpected '=' before an attribute name."
          when ERR_UNEXPECTED_NULL_CHARACTER
            "Input contains unexpected U+0000."
          when ERR_UNEXPECTED_QUESTION_MARK_INSTEAD_OF_TAG_NAME
            "Unexpected '?' where start tag name is expected."
          when ERR_UNEXPECTED_SOLIDUS_IN_TAG
            "Unexpected '/' in tag."
          when ERR_UNKNOWN_NAMED_CHARACTER_REFERENCE
            "Unknown named character reference '".b + original_text(source) + "'."
          when ERR_UTF8_INVALID
            "Invalid UTF8 encoding."
          when ERR_UTF8_TRUNCATED
            "UTF8 character truncated."
          else
            ""
          end
          out << msg.b
        end

        def print_tag_stack(out)
          out << " Currently open tags: "
          @tag_stack.each_with_index do |tag, i|
            out << ", " if i > 0
            out << (tag.is_a?(String) ? tag : TAG_NAMES[tag])
          end
          out << "."
        end

        def parser_message(out)
          if @parser_state == INSERTION_MODE_INITIAL && @input_type != TOKEN_DOCTYPE
            out << "Expected a doctype token"
            return
          end

          case @input_type
          when TOKEN_DOCTYPE
            out << "This is not a legal doctype"
          when TOKEN_COMMENT
            out << "Comments aren't legal here"
          when TOKEN_CDATA, TOKEN_WHITESPACE, TOKEN_CHARACTER
            out << "Character tokens aren't legal here"
          when TOKEN_NULL
            out << "Null bytes are not allowed in HTML5"
          when TOKEN_EOF
            if @parser_state == INSERTION_MODE_INITIAL
              out << "You must provide a doctype"
            else
              out << "Premature end of file."
              print_tag_stack(out)
            end
          when TOKEN_START_TAG, TOKEN_END_TAG
            which = @input_type == TOKEN_START_TAG ? "Start" : "End"
            tag_name = @input_name || TAG_NAMES[@input_tag]
            out << which << " tag '" << tag_name << "' isn't allowed here."
            print_tag_stack(out)
          end
        end

        def find_prev_newline(source, loc)
          len = source.bytesize
          c = loc
          c -= 1 if c != 0 && (loc == len || source.getbyte(c) == 0x0a)
          c -= 1 while c != 0 && source.getbyte(c) != 0x0a
          c == 0 ? c : c + 1
        end

        def find_next_newline(source, loc)
          len = source.bytesize
          c = loc
          c += 1 while c != len && source.getbyte(c) != 0x0a
          c
        end
      end
    end
  end
end
