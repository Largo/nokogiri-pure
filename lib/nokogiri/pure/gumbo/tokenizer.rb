# frozen_string_literal: true

# Port of gumbo-parser's tokenizer.c and utf8.c.
#
# The input is a binary (ASCII-8BIT) String; all positions are byte offsets into it. Strings
# accumulated by the tokenizer (tag names, attribute names/values, comments, doctype fields) are
# binary Strings holding UTF-8 bytes.

require "strscan"

module Nokogiri
  module Pure
    module Gumbo
      # GumboToken. The parser reuses a single instance, exactly like the C code does.
      class Token
        attr_accessor :type, :line, :column, :offset, :orig_start, :orig_len,
          :character, :tag, :name, :attributes, :is_self_closing, :text, :doc_type

        def initialize
          @type = TOKEN_EOF
          @line = 0
          @column = 0
          @offset = 0
          @orig_start = 0
          @orig_len = 0
          @character = -1
          @tag = TAG_UNKNOWN
          @name = nil
          @attributes = nil
          @is_self_closing = false
          @text = nil
          @doc_type = nil
        end
      end

      # GumboTokenDocType
      class DocTypeToken
        attr_accessor :name, :public_identifier, :system_identifier, :force_quirks,
          :has_public_identifier, :has_system_identifier

        def initialize
          @name = nil
          @public_identifier = nil
          @system_identifier = nil
          @force_quirks = false
          @has_public_identifier = false
          @has_system_identifier = false
        end
      end

      # GumboAttribute (only the fields that are observable are kept)
      class Attribute
        attr_accessor :attr_namespace, :name, :value, :orig_name_len

        def initialize(name, value, orig_name_len)
          @attr_namespace = ATTR_NAMESPACE_NONE
          @name = name
          @value = value
          @orig_name_len = orig_name_len
        end
      end

      class Tokenizer
        # utf8.c decoding table (Bjoern Hoehrmann's DFA)
        UTF8D = [
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
          7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
          8, 8, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
          10, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 4, 3, 3, 11, 6, 6, 6, 5, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,

          0, 12, 24, 36, 60, 96, 84, 12, 12, 12, 48, 72, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
          12, 0, 12, 12, 12, 12, 12, 0, 12, 0, 12, 12, 12, 24, 12, 12, 12, 12, 12, 24, 12, 24, 12, 12,
          12, 12, 12, 12, 12, 12, 12, 24, 12, 12, 12, 12, 12, 24, 12, 12, 12, 12, 12, 12, 12, 24, 12, 12,
          12, 12, 12, 12, 12, 12, 12, 36, 12, 36, 12, 12, 12, 36, 12, 12, 12, 12, 12, 36, 12, 36, 12, 12,
          12, 36, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
        ].freeze
        UTF8_ACCEPT = 0
        UTF8_REJECT = 12

        # control characters that are reported by read_char: utf8_is_control(c) && !isspace && c != 0
        ASCII_CONTROL_ERROR = Array.new(128) do |c|
          (c < 0x1f || c == 0x7f) && ![0x09, 0x0a, 0x0c, 0x0d, 0x20, 0].include?(c)
        end.freeze

        SCRIPT_TAG = "script".b.freeze
        EMPTY = "".b.freeze

        attr_reader :state, :input, :line, :current

        def initialize(parser, input, tab_stop)
          @parser = parser
          @input = input
          @tab_stop = tab_stop

          # GumboTokenizerState
          @state = LEX_DATA
          @return_state = LEX_DATA
          @character_reference_code = 0
          @reconsume = false
          @is_adjusted_current_node_foreign = false
          @is_in_cdata = false
          @buffered_emit_char = NO_CHAR
          @temporary_buffer = +""
          @temporary_buffer.force_encoding(Encoding::BINARY)
          @resume_pos = nil

          # GumboTagState
          @tag_buffer = +""
          @tag_buffer.force_encoding(Encoding::BINARY)
          @tag_original_text = 0
          @tag = TAG_UNKNOWN
          @tag_name = nil
          @tag_start_line = 0
          @tag_start_column = 0
          @tag_start_offset = 0
          @tag_attributes = nil
          @drop_next_attr_value = false
          @last_start_tag = TAG_LAST
          @is_start_tag = false
          @is_self_closing = false

          @doc_type_state = DocTypeToken.new

          # Utf8Iterator
          @start = 0
          @end = input.bytesize
          @mark = 0
          @current = -1
          @width = 0
          @line = 1
          @column = 1
          @offset = 0
          @mark_line = 1
          @mark_column = 1
          @mark_offset = 0
          read_char
          if @current == BOM_CHAR
            @start += @width
            @offset += @width
            read_char
          end

          @token_start_line = @line
          @token_start_column = @column
          @token_start_offset = @offset
          @token_start = @start
        end

        # ---- utf8.c -------------------------------------------------------------------

        def utf8_add_error(type)
          error = @parser.add_error
          return unless error

          error.type = type
          error.line = @line
          error.column = @column
          error.offset = @offset
          error.orig_start = @start
          error.orig_len = @width
          error.codepoint = @current
        end

        def read_char
          start = @start
          if start >= @end
            @current = -1
            @width = 0
            return
          end
          input = @input
          b = input.getbyte(start)
          if b < 0x80
            @width = 1
            if b == 0x0d
              if start + 1 < @end && input.getbyte(start + 1) == 0x0a
                @start = start + 1
                @offset += 1
              end
              b = 0x0a
            end
            @current = b
            utf8_add_error(ERR_CONTROL_CHARACTER_IN_INPUT_STREAM) if ASCII_CONTROL_ERROR[b]
            return
          end

          code_point = 0
          state = UTF8_ACCEPT
          c = start
          stop = @end
          while c < stop
            byte = input.getbyte(c)
            type = UTF8D[byte]
            code_point = state != UTF8_ACCEPT ? (byte & 0x3f) | (code_point << 6) : (0xff >> type) & byte
            state = UTF8D[256 + state + type]
            if state == UTF8_ACCEPT
              @width = c - start + 1
              @current = code_point
              if code_point >= 0xD800 && code_point <= 0xDFFF
                utf8_add_error(ERR_SURROGATE_IN_INPUT_STREAM)
              elsif (code_point >= 0xFDD0 && code_point <= 0xFDEF) || (code_point & 0xFFFF) >= 0xFFFE
                utf8_add_error(ERR_NONCHARACTER_IN_INPUT_STREAM)
              elsif code_point >= 0x7F && code_point <= 0x9F
                utf8_add_error(ERR_CONTROL_CHARACTER_IN_INPUT_STREAM)
              end
              return
            elsif state == UTF8_REJECT
              @width = c - start + (c == start ? 1 : 0)
              @current = REPLACEMENT_CHAR
              utf8_add_error(ERR_UTF8_INVALID)
              return
            end
            c += 1
          end
          @width = @end - start
          @current = REPLACEMENT_CHAR
          utf8_add_error(ERR_UTF8_TRUNCATED)
        end

        # utf8iterator_next
        def iter_next
          c = @current
          @offset += @width
          if c == 0x0a
            @line += 1
            @column = 1
          elsif c == 0x09
            @column = ((@column / @tab_stop) + 1) * @tab_stop
          elsif c != -1
            @column += 1
          end
          @start += @width
          read_char
        end

        def iter_mark
          @mark = @start
          @mark_line = @line
          @mark_column = @column
          @mark_offset = @offset
        end

        def iter_reset
          @start = @mark
          @line = @mark_line
          @column = @mark_column
          @offset = @mark_offset
          read_char
        end

        # utf8iterator_maybe_consume_match. `prefix` is a binary String.
        def maybe_consume_match(prefix, case_sensitive)
          length = prefix.bytesize
          return false unless @start + length <= @end

          str = @input.byteslice(@start, length)
          matched = if case_sensitive
            str == prefix
          else
            str.casecmp(prefix) == 0 && !str.include?("\0")
          end
          return false unless matched

          length.times { iter_next }
          true
        end

        # ---- tokenizer.c --------------------------------------------------------------

        def set_state(state)
          @state = state
        end

        def set_is_adjusted_current_node_foreign(is_foreign)
          @is_adjusted_current_node_foreign = is_foreign
        end

        def tokenizer_add_parse_error(type)
          error = @parser.add_error
          return unless error

          error.line = @line
          error.column = @column
          error.offset = @offset
          error.orig_start = @start
          error.orig_len = @width
          error.type = type
          error.state = @state
          error.codepoint = @current
        end

        def tokenizer_add_char_ref_error(type, codepoint)
          error = @parser.add_error
          return unless error

          error.type = type
          error.line = @mark_line
          error.column = @mark_column
          error.offset = @mark_offset
          error.orig_start = @mark
          error.orig_len = @start - @mark
          error.state = @state
          error.codepoint = codepoint
        end

        def tokenizer_add_token_parse_error(type)
          error = @parser.add_error
          return unless error

          error.type = type
          error.line = @token_start_line
          error.column = @token_start_column
          error.offset = @token_start_offset
          error.orig_start = @token_start
          error.orig_len = @start - @token_start
          error.state = @state
          error.codepoint = 0
        end

        def get_char_token_type(c)
          return TOKEN_CDATA if @is_in_cdata && c > 0

          case c
          when 0x09, 0x0a, 0x0d, 0x0c, 0x20 then TOKEN_WHITESPACE
          when 0 then TOKEN_NULL
          when -1 then TOKEN_EOF
          else TOKEN_CHARACTER
          end
        end

        def clear_temporary_buffer
          @temporary_buffer.clear
        end

        def append_char_to_temporary_buffer(c)
          if c < 0x80
            @temporary_buffer << c
          else
            Util.append_codepoint(@temporary_buffer, c)
          end
        end

        def reset_token_start_point
          @token_start = @start
          @token_start_line = @line
          @token_start_column = @column
          @token_start_offset = @offset
        end

        def reset_tag_buffer_start_point
          @tag_start_line = @line
          @tag_start_column = @column
          @tag_start_offset = @offset
          @tag_original_text = @start
        end

        def finish_temporary_buffer
          s = @temporary_buffer.dup
          @temporary_buffer.clear
          s
        end

        def finish_token(token)
          iter_next unless @reconsume

          token.line = @token_start_line
          token.column = @token_start_column
          token.offset = @token_start_offset
          orig = @token_start
          token.orig_start = orig
          reset_token_start_point
          len = @token_start - orig
          len -= 1 if len > 0 && @input.getbyte(orig + len - 1) == 0x0d
          token.orig_len = len
        end

        def finish_doctype_public_id
          @doc_type_state.public_identifier = finish_temporary_buffer
          @doc_type_state.has_public_identifier = true
        end

        def finish_doctype_system_id
          @doc_type_state.system_identifier = finish_temporary_buffer
          @doc_type_state.has_system_identifier = true
        end

        def emit_char(c, output)
          output.type = get_char_token_type(c)
          output.character = c
          finish_token(output)
          true
        end

        def emit_replacement_char(output)
          tokenizer_add_parse_error(ERR_UNEXPECTED_NULL_CHARACTER)
          emit_char(REPLACEMENT_CHAR, output)
        end

        def emit_eof(output)
          emit_char(-1, output)
        end

        def emit_doctype(output)
          output.type = TOKEN_DOCTYPE
          output.doc_type = @doc_type_state
          finish_token(output)
          @doc_type_state = DocTypeToken.new
          true
        end

        def emit_current_tag(output)
          if @is_start_tag
            output.type = TOKEN_START_TAG
            output.tag = @tag
            output.name = @tag_name
            output.attributes = @tag_attributes
            output.is_self_closing = @is_self_closing
            @last_start_tag = @tag
          else
            output.type = TOKEN_END_TAG
            output.tag = @tag
            output.name = @tag_name
            tokenizer_add_token_parse_error(ERR_END_TAG_WITH_TRAILING_SOLIDUS) if @is_self_closing
            tokenizer_add_token_parse_error(ERR_END_TAG_WITH_ATTRIBUTES) if @tag_attributes.length > 0
          end
          @tag_name = nil
          @tag_attributes = nil
          @tag_buffer = +""
          @tag_buffer.force_encoding(Encoding::BINARY)
          finish_token(output)
          true
        end

        def abandon_current_tag
          @tag_attributes = nil
          @tag_name = nil
          @tag_buffer = +""
          @tag_buffer.force_encoding(Encoding::BINARY)
        end

        def emit_comment(output)
          output.type = TOKEN_COMMENT
          output.text = finish_temporary_buffer
          finish_token(output)
          true
        end

        def set_mark
          iter_mark
        end

        def maybe_emit_from_mark(output)
          pos = @resume_pos
          return false unless pos

          if @start >= pos
            @resume_pos = nil
            return false
          end
          emit_char(@current, output)
        end

        def emit_from_mark(output)
          @resume_pos = @start
          iter_reset
          @reconsume = false
          maybe_emit_from_mark(output)
        end

        def append_char_to_tag_buffer(c, reinitialize_position_on_first)
          buffer = @tag_buffer
          reset_tag_buffer_start_point if buffer.empty? && reinitialize_position_on_first
          if c < 0x80
            buffer << c
          else
            Util.append_codepoint(buffer, c)
          end
        end

        def append_string_to_tag_buffer(str, reinitialize_position_on_first)
          reset_tag_buffer_start_point if @tag_buffer.empty? && reinitialize_position_on_first
          @tag_buffer << str
        end

        def initialize_tag_buffer
          @tag_buffer.clear
          reset_tag_buffer_start_point
        end

        def character_reference_part_of_attribute
          rs = @return_state
          rs == LEX_ATTR_VALUE_DOUBLE_QUOTED || rs == LEX_ATTR_VALUE_SINGLE_QUOTED ||
            rs == LEX_ATTR_VALUE_UNQUOTED
        end

        def flush_code_points_consumed_as_character_reference(output)
          if character_reference_part_of_attribute
            start = @mark
            str = @input.byteslice(start, @start - start)
            append_string_to_tag_buffer(str, @return_state == LEX_ATTR_VALUE_UNQUOTED)
            return false
          end
          emit_from_mark(output)
        end

        def flush_char_ref(first, second, output)
          if character_reference_part_of_attribute
            unquoted = @return_state == LEX_ATTR_VALUE_UNQUOTED
            append_char_to_tag_buffer(first, unquoted)
            append_char_to_tag_buffer(second, unquoted) if second != NO_CHAR
            return false
          end
          @buffered_emit_char = second
          emit_char(first, output)
        end

        def start_new_tag(is_start_tag)
          initialize_tag_buffer
          @tag_attributes = []
          @drop_next_attr_value = false
          @is_start_tag = is_start_tag
          @is_self_closing = false
        end

        # copy_over_original_tag_text: returns the length of the original text
        def original_tag_text_length
          len = @start - @tag_original_text
          len -= 1 if len > 0 && @input.getbyte(@tag_original_text + len - 1) == 0x0d
          len
        end

        def reinitialize_tag_buffer
          initialize_tag_buffer
        end

        def finish_tag_name
          buf = @tag_buffer
          @tag = Util.tagn_enum(buf)
          @tag_name = buf.dup if @tag == TAG_UNKNOWN
          reinitialize_tag_buffer
        end

        def add_duplicate_attr_error
          error = @parser.add_error
          return unless error

          error.type = ERR_DUPLICATE_ATTRIBUTE
          error.line = @tag_start_line
          error.column = @tag_start_column
          error.offset = @tag_start_offset
          error.orig_start = @tag_original_text
          error.orig_len = @start - @tag_original_text
          error.state = @state
        end

        def finish_attribute_name
          attributes = @tag_attributes
          max_attributes = @parser.max_attributes
          if max_attributes >= 0 && attributes.length >= max_attributes
            @parser.output_status = STATUS_TOO_MANY_ATTRIBUTES
            reinitialize_tag_buffer
            @drop_next_attr_value = true
            return
          end

          @drop_next_attr_value = false
          buf = @tag_buffer
          # attr->name is a C string, so compare up to the first NUL (there are none in practice)
          attributes.each do |attr|
            next unless attr.name == buf

            add_duplicate_attr_error
            reinitialize_tag_buffer
            @drop_next_attr_value = true
            return
          end

          attributes << Attribute.new(buf.dup, EMPTY.dup, original_tag_text_length)
          reinitialize_tag_buffer
        end

        def finish_attribute_value
          if @drop_next_attr_value
            @drop_next_attr_value = false
            reinitialize_tag_buffer
            return
          end
          @tag_attributes[-1].value = @tag_buffer.dup
          reinitialize_tag_buffer
        end

        def is_appropriate_end_tag
          @last_start_tag != TAG_LAST && @last_start_tag == Util.tagn_enum(@tag_buffer)
        end

        def reconsume_in_state(state)
          @reconsume = true
          @state = state
        end

        # ---- state handlers -----------------------------------------------------------

        def handle_data_state(c, output)
          case c
          when 0x26 # &
            @state = LEX_CHARACTER_REFERENCE
            set_mark
            @return_state = LEX_DATA
            false
          when 0x3c # <
            @state = LEX_TAG_OPEN
            set_mark
            false
          when 0
            tokenizer_add_parse_error(ERR_UNEXPECTED_NULL_CHARACTER)
            emit_char(c, output)
          when -1
            emit_eof(output)
          else
            emit_char(c, output)
          end
        end

        def handle_rcdata_state(c, output)
          case c
          when 0x26
            @state = LEX_CHARACTER_REFERENCE
            set_mark
            @return_state = LEX_RCDATA
            false
          when 0x3c
            @state = LEX_RCDATA_LT
            set_mark
            false
          when 0
            emit_replacement_char(output)
          when -1
            emit_eof(output)
          else
            emit_char(c, output)
          end
        end

        def handle_rawtext_state(c, output)
          case c
          when 0x3c
            @state = LEX_RAWTEXT_LT
            set_mark
            false
          when 0
            emit_replacement_char(output)
          when -1
            emit_eof(output)
          else
            emit_char(c, output)
          end
        end

        def handle_script_data_state(c, output)
          case c
          when 0x3c
            @state = LEX_SCRIPT_DATA_LT
            set_mark
            false
          when 0
            emit_replacement_char(output)
          when -1
            emit_eof(output)
          else
            emit_char(c, output)
          end
        end

        def handle_plaintext_state(c, output)
          case c
          when 0
            emit_replacement_char(output)
          when -1
            emit_eof(output)
          else
            emit_char(c, output)
          end
        end

        def handle_tag_open_state(c, output)
          case c
          when 0x21 # !
            @state = LEX_MARKUP_DECLARATION_OPEN
            clear_temporary_buffer
            false
          when 0x2f # /
            @state = LEX_END_TAG_OPEN
            false
          when 0x3f # ?
            tokenizer_add_parse_error(ERR_UNEXPECTED_QUESTION_MARK_INSTEAD_OF_TAG_NAME)
            clear_temporary_buffer
            reconsume_in_state(LEX_BOGUS_COMMENT)
            false
          when -1
            tokenizer_add_parse_error(ERR_EOF_BEFORE_TAG_NAME)
            reconsume_in_state(LEX_DATA)
            emit_from_mark(output)
          else
            if Util.ascii_isalpha(c)
              reconsume_in_state(LEX_TAG_NAME)
              start_new_tag(true)
              return false
            end
            tokenizer_add_parse_error(ERR_INVALID_FIRST_CHARACTER_OF_TAG_NAME)
            reconsume_in_state(LEX_DATA)
            emit_from_mark(output)
          end
        end

        def handle_end_tag_open_state(c, output)
          case c
          when 0x3e # >
            tokenizer_add_parse_error(ERR_MISSING_END_TAG_NAME)
            @state = LEX_DATA
            false
          when -1
            tokenizer_add_parse_error(ERR_EOF_BEFORE_TAG_NAME)
            reconsume_in_state(LEX_DATA)
            emit_from_mark(output)
          else
            if Util.ascii_isalpha(c)
              reconsume_in_state(LEX_TAG_NAME)
              start_new_tag(false)
            else
              tokenizer_add_parse_error(ERR_INVALID_FIRST_CHARACTER_OF_TAG_NAME)
              reconsume_in_state(LEX_BOGUS_COMMENT)
              clear_temporary_buffer
            end
            false
          end
        end

        def handle_tag_name_state(c, output)
          case c
          when 0x09, 0x0a, 0x0c, 0x20
            finish_tag_name
            @state = LEX_BEFORE_ATTR_NAME
            false
          when 0x2f
            finish_tag_name
            @state = LEX_SELF_CLOSING_START_TAG
            false
          when 0x3e
            finish_tag_name
            @state = LEX_DATA
            emit_current_tag(output)
          when 0
            tokenizer_add_parse_error(ERR_UNEXPECTED_NULL_CHARACTER)
            append_char_to_tag_buffer(REPLACEMENT_CHAR, true)
            false
          when -1
            tokenizer_add_parse_error(ERR_EOF_IN_TAG)
            abandon_current_tag
            emit_eof(output)
          else
            append_char_to_tag_buffer(Util.ascii_tolower(c), true)
            if (run = consume_run(RUN_TAG_NAME))
              @tag_buffer << run.downcase
            end
            false
          end
        end

        def handle_rcdata_lt_state(c, output)
          if c == 0x2f
            @state = LEX_RCDATA_END_TAG_OPEN
            false
          else
            reconsume_in_state(LEX_RCDATA)
            emit_from_mark(output)
          end
        end

        def handle_rcdata_end_tag_open_state(c, output)
          if Util.ascii_isalpha(c)
            reconsume_in_state(LEX_RCDATA_END_TAG_NAME)
            start_new_tag(false)
            return false
          end
          reconsume_in_state(LEX_RCDATA)
          emit_from_mark(output)
        end

        # shared implementation of the {rcdata,rawtext,script data,script data escaped} end tag
        # name states
        def end_tag_name_state(c, output, fallback_state)
          if Util.ascii_isalpha(c)
            append_char_to_tag_buffer(Util.ascii_tolower(c), true)
            return false
          end
          case c
          when 0x09, 0x0a, 0x0c, 0x20
            if is_appropriate_end_tag
              finish_tag_name
              @state = LEX_BEFORE_ATTR_NAME
              return false
            end
          when 0x2f
            if is_appropriate_end_tag
              finish_tag_name
              @state = LEX_SELF_CLOSING_START_TAG
              return false
            end
          when 0x3e
            if is_appropriate_end_tag
              finish_tag_name
              @state = LEX_DATA
              return emit_current_tag(output)
            end
          end
          abandon_current_tag
          reconsume_in_state(fallback_state)
          emit_from_mark(output)
        end

        def handle_rcdata_end_tag_name_state(c, output)
          end_tag_name_state(c, output, LEX_RCDATA)
        end

        def handle_rawtext_lt_state(c, output)
          if c == 0x2f
            @state = LEX_RAWTEXT_END_TAG_OPEN
            false
          else
            reconsume_in_state(LEX_RAWTEXT)
            emit_from_mark(output)
          end
        end

        def handle_rawtext_end_tag_open_state(c, output)
          if Util.ascii_isalpha(c)
            reconsume_in_state(LEX_RAWTEXT_END_TAG_NAME)
            start_new_tag(false)
            false
          else
            reconsume_in_state(LEX_RAWTEXT)
            emit_from_mark(output)
          end
        end

        def handle_rawtext_end_tag_name_state(c, output)
          end_tag_name_state(c, output, LEX_RAWTEXT)
        end

        def handle_script_data_lt_state(c, output)
          if c == 0x2f
            @state = LEX_SCRIPT_DATA_END_TAG_OPEN
            return false
          end
          if c == 0x21
            iter_next
            reconsume_in_state(LEX_SCRIPT_DATA_ESCAPED_START)
            return emit_from_mark(output)
          end
          reconsume_in_state(LEX_SCRIPT_DATA)
          emit_from_mark(output)
        end

        def handle_script_data_end_tag_open_state(c, output)
          if Util.ascii_isalpha(c)
            reconsume_in_state(LEX_SCRIPT_DATA_END_TAG_NAME)
            start_new_tag(false)
            return false
          end
          reconsume_in_state(LEX_SCRIPT_DATA)
          emit_from_mark(output)
        end

        def handle_script_data_end_tag_name_state(c, output)
          end_tag_name_state(c, output, LEX_SCRIPT_DATA)
        end

        def handle_script_data_escaped_start_state(c, output)
          if c == 0x2d
            @state = LEX_SCRIPT_DATA_ESCAPED_START_DASH
            return emit_char(c, output)
          end
          reconsume_in_state(LEX_SCRIPT_DATA)
          false
        end

        def handle_script_data_escaped_start_dash_state(c, output)
          if c == 0x2d
            @state = LEX_SCRIPT_DATA_ESCAPED_DASH_DASH
            emit_char(c, output)
          else
            reconsume_in_state(LEX_SCRIPT_DATA)
            false
          end
        end

        def handle_script_data_escaped_state(c, output)
          case c
          when 0x2d
            @state = LEX_SCRIPT_DATA_ESCAPED_DASH
            emit_char(c, output)
          when 0x3c
            @state = LEX_SCRIPT_DATA_ESCAPED_LT
            clear_temporary_buffer
            set_mark
            false
          when 0
            emit_replacement_char(output)
          when -1
            tokenizer_add_parse_error(ERR_EOF_IN_SCRIPT_HTML_COMMENT_LIKE_TEXT)
            emit_eof(output)
          else
            emit_char(c, output)
          end
        end

        def handle_script_data_escaped_dash_state(c, output)
          case c
          when 0x2d
            @state = LEX_SCRIPT_DATA_ESCAPED_DASH_DASH
            emit_char(c, output)
          when 0x3c
            @state = LEX_SCRIPT_DATA_ESCAPED_LT
            clear_temporary_buffer
            set_mark
            false
          when 0
            @state = LEX_SCRIPT_DATA_ESCAPED
            emit_replacement_char(output)
          when -1
            tokenizer_add_parse_error(ERR_EOF_IN_SCRIPT_HTML_COMMENT_LIKE_TEXT)
            emit_eof(output)
          else
            @state = LEX_SCRIPT_DATA_ESCAPED
            emit_char(c, output)
          end
        end

        def handle_script_data_escaped_dash_dash_state(c, output)
          case c
          when 0x2d
            emit_char(c, output)
          when 0x3c
            @state = LEX_SCRIPT_DATA_ESCAPED_LT
            clear_temporary_buffer
            set_mark
            false
          when 0x3e
            @state = LEX_SCRIPT_DATA
            emit_char(c, output)
          when 0
            @state = LEX_SCRIPT_DATA_ESCAPED
            emit_replacement_char(output)
          when -1
            tokenizer_add_parse_error(ERR_EOF_IN_SCRIPT_HTML_COMMENT_LIKE_TEXT)
            emit_eof(output)
          else
            @state = LEX_SCRIPT_DATA_ESCAPED
            emit_char(c, output)
          end
        end

        def handle_script_data_escaped_lt_state(c, output)
          if c == 0x2f
            @state = LEX_SCRIPT_DATA_ESCAPED_END_TAG_OPEN
            return false
          end
          if Util.ascii_isalpha(c)
            reconsume_in_state(LEX_SCRIPT_DATA_DOUBLE_ESCAPED_START)
            return emit_from_mark(output)
          end
          reconsume_in_state(LEX_SCRIPT_DATA_ESCAPED)
          emit_from_mark(output)
        end

        def handle_script_data_escaped_end_tag_open_state(c, output)
          if Util.ascii_isalpha(c)
            reconsume_in_state(LEX_SCRIPT_DATA_ESCAPED_END_TAG_NAME)
            start_new_tag(false)
            return false
          end
          reconsume_in_state(LEX_SCRIPT_DATA_ESCAPED)
          emit_from_mark(output)
        end

        def handle_script_data_escaped_end_tag_name_state(c, output)
          end_tag_name_state(c, output, LEX_SCRIPT_DATA_ESCAPED)
        end

        def handle_script_data_double_escaped_start_state(c, output)
          case c
          when 0x09, 0x0a, 0x0c, 0x20, 0x2f, 0x3e
            @state = @temporary_buffer == SCRIPT_TAG ? LEX_SCRIPT_DATA_DOUBLE_ESCAPED : LEX_SCRIPT_DATA_ESCAPED
            return emit_char(c, output)
          end
          if Util.ascii_isalpha(c)
            append_char_to_temporary_buffer(Util.ascii_tolower(c))
            return emit_char(c, output)
          end
          reconsume_in_state(LEX_SCRIPT_DATA_ESCAPED)
          false
        end

        def handle_script_data_double_escaped_state(c, output)
          case c
          when 0x2d
            @state = LEX_SCRIPT_DATA_DOUBLE_ESCAPED_DASH
            emit_char(c, output)
          when 0x3c
            @state = LEX_SCRIPT_DATA_DOUBLE_ESCAPED_LT
            emit_char(c, output)
          when 0
            emit_replacement_char(output)
          when -1
            tokenizer_add_parse_error(ERR_EOF_IN_SCRIPT_HTML_COMMENT_LIKE_TEXT)
            emit_eof(output)
          else
            emit_char(c, output)
          end
        end

        def handle_script_data_double_escaped_dash_state(c, output)
          case c
          when 0x2d
            @state = LEX_SCRIPT_DATA_DOUBLE_ESCAPED_DASH_DASH
            emit_char(c, output)
          when 0x3c
            @state = LEX_SCRIPT_DATA_DOUBLE_ESCAPED_LT
            emit_char(c, output)
          when 0
            @state = LEX_SCRIPT_DATA_DOUBLE_ESCAPED
            emit_replacement_char(output)
          when -1
            tokenizer_add_parse_error(ERR_EOF_IN_SCRIPT_HTML_COMMENT_LIKE_TEXT)
            emit_eof(output)
          else
            @state = LEX_SCRIPT_DATA_DOUBLE_ESCAPED
            emit_char(c, output)
          end
        end

        def handle_script_data_double_escaped_dash_dash_state(c, output)
          case c
          when 0x2d
            emit_char(c, output)
          when 0x3c
            @state = LEX_SCRIPT_DATA_DOUBLE_ESCAPED_LT
            emit_char(c, output)
          when 0x3e
            @state = LEX_SCRIPT_DATA
            emit_char(c, output)
          when 0
            @state = LEX_SCRIPT_DATA_DOUBLE_ESCAPED
            emit_replacement_char(output)
          when -1
            tokenizer_add_parse_error(ERR_EOF_IN_SCRIPT_HTML_COMMENT_LIKE_TEXT)
            emit_eof(output)
          else
            @state = LEX_SCRIPT_DATA_DOUBLE_ESCAPED
            emit_char(c, output)
          end
        end

        def handle_script_data_double_escaped_lt_state(c, output)
          if c == 0x2f
            @state = LEX_SCRIPT_DATA_DOUBLE_ESCAPED_END
            clear_temporary_buffer
            emit_char(c, output)
          else
            reconsume_in_state(LEX_SCRIPT_DATA_DOUBLE_ESCAPED)
            false
          end
        end

        def handle_script_data_double_escaped_end_state(c, output)
          case c
          when 0x09, 0x0a, 0x0c, 0x20, 0x2f, 0x3e
            @state = @temporary_buffer == SCRIPT_TAG ? LEX_SCRIPT_DATA_ESCAPED : LEX_SCRIPT_DATA_DOUBLE_ESCAPED
            return emit_char(c, output)
          end
          if Util.ascii_isalpha(c)
            append_char_to_temporary_buffer(Util.ascii_tolower(c))
            return emit_char(c, output)
          end
          reconsume_in_state(LEX_SCRIPT_DATA_DOUBLE_ESCAPED)
          false
        end

        def handle_before_attr_name_state(c, output)
          case c
          when 0x09, 0x0a, 0x0c, 0x20
            false
          when 0x2f, 0x3e, -1
            reconsume_in_state(LEX_AFTER_ATTR_NAME)
            false
          when 0x3d # =
            tokenizer_add_parse_error(ERR_UNEXPECTED_EQUALS_SIGN_BEFORE_ATTRIBUTE_NAME)
            @state = LEX_ATTR_NAME
            append_char_to_tag_buffer(c, true)
            false
          else
            reconsume_in_state(LEX_ATTR_NAME)
            false
          end
        end

        def handle_attr_name_state(c, output)
          case c
          when 0x09, 0x0a, 0x0c, 0x20, 0x2f, 0x3e, -1
            finish_attribute_name
            reconsume_in_state(LEX_AFTER_ATTR_NAME)
            false
          when 0x3d
            finish_attribute_name
            @state = LEX_BEFORE_ATTR_VALUE
            false
          when 0
            tokenizer_add_parse_error(ERR_UNEXPECTED_NULL_CHARACTER)
            append_char_to_tag_buffer(REPLACEMENT_CHAR, true)
            false
          when 0x22, 0x27, 0x3c
            tokenizer_add_parse_error(ERR_UNEXPECTED_CHARACTER_IN_ATTRIBUTE_NAME)
            append_char_to_tag_buffer(Util.ascii_tolower(c), true)
            false
          else
            append_char_to_tag_buffer(Util.ascii_tolower(c), true)
            if (run = consume_run(RUN_ATTR_NAME))
              @tag_buffer << run.downcase
            end
            false
          end
        end

        def handle_after_attr_name_state(c, output)
          case c
          when 0x09, 0x0a, 0x0c, 0x20
            false
          when 0x2f
            @state = LEX_SELF_CLOSING_START_TAG
            false
          when 0x3d
            @state = LEX_BEFORE_ATTR_VALUE
            false
          when 0x3e
            @state = LEX_DATA
            emit_current_tag(output)
          when -1
            tokenizer_add_parse_error(ERR_EOF_IN_TAG)
            abandon_current_tag
            emit_eof(output)
          else
            reconsume_in_state(LEX_ATTR_NAME)
            false
          end
        end

        def handle_before_attr_value_state(c, output)
          case c
          when 0x09, 0x0a, 0x0c, 0x20
            return false
          when 0x22
            @state = LEX_ATTR_VALUE_DOUBLE_QUOTED
            reset_tag_buffer_start_point
            return false
          when 0x27
            @state = LEX_ATTR_VALUE_SINGLE_QUOTED
            reset_tag_buffer_start_point
            return false
          when 0x3e
            tokenizer_add_parse_error(ERR_MISSING_ATTRIBUTE_VALUE)
            @state = LEX_DATA
            return emit_current_tag(output)
          end
          reconsume_in_state(LEX_ATTR_VALUE_UNQUOTED)
          false
        end

        def handle_attr_value_double_quoted_state(c, output)
          case c
          when 0x22
            @state = LEX_AFTER_ATTR_VALUE_QUOTED
            false
          when 0x26
            @state = LEX_CHARACTER_REFERENCE
            set_mark
            @return_state = LEX_ATTR_VALUE_DOUBLE_QUOTED
            false
          when 0
            tokenizer_add_parse_error(ERR_UNEXPECTED_NULL_CHARACTER)
            append_char_to_tag_buffer(REPLACEMENT_CHAR, false)
            false
          when -1
            tokenizer_add_parse_error(ERR_EOF_IN_TAG)
            abandon_current_tag
            emit_eof(output)
          else
            append_char_to_tag_buffer(c, false)
            if (run = consume_run(RUN_ATTR_VALUE_DQ))
              @tag_buffer << run
            end
            false
          end
        end

        def handle_attr_value_single_quoted_state(c, output)
          case c
          when 0x27
            @state = LEX_AFTER_ATTR_VALUE_QUOTED
            false
          when 0x26
            @state = LEX_CHARACTER_REFERENCE
            set_mark
            @return_state = LEX_ATTR_VALUE_SINGLE_QUOTED
            false
          when 0
            tokenizer_add_parse_error(ERR_UNEXPECTED_NULL_CHARACTER)
            append_char_to_tag_buffer(REPLACEMENT_CHAR, false)
            false
          when -1
            tokenizer_add_parse_error(ERR_EOF_IN_TAG)
            abandon_current_tag
            emit_eof(output)
          else
            append_char_to_tag_buffer(c, false)
            if (run = consume_run(RUN_ATTR_VALUE_SQ))
              @tag_buffer << run
            end
            false
          end
        end

        def handle_attr_value_unquoted_state(c, output)
          case c
          when 0x09, 0x0a, 0x0c, 0x20
            @state = LEX_BEFORE_ATTR_NAME
            finish_attribute_value
            false
          when 0x26
            @state = LEX_CHARACTER_REFERENCE
            set_mark
            @return_state = LEX_ATTR_VALUE_UNQUOTED
            false
          when 0x3e
            @state = LEX_DATA
            finish_attribute_value
            emit_current_tag(output)
          when 0
            tokenizer_add_parse_error(ERR_UNEXPECTED_NULL_CHARACTER)
            append_char_to_tag_buffer(REPLACEMENT_CHAR, true)
            false
          when -1
            tokenizer_add_parse_error(ERR_EOF_IN_TAG)
            abandon_current_tag
            emit_eof(output)
          when 0x22, 0x27, 0x3c, 0x3d, 0x60
            tokenizer_add_parse_error(ERR_UNEXPECTED_CHARACTER_IN_UNQUOTED_ATTRIBUTE_VALUE)
            append_char_to_tag_buffer(c, true)
            false
          else
            append_char_to_tag_buffer(c, true)
            if (run = consume_run(RUN_ATTR_VALUE_UQ))
              @tag_buffer << run
            end
            false
          end
        end

        def handle_after_attr_value_quoted_state(c, output)
          finish_attribute_value
          case c
          when 0x09, 0x0a, 0x0c, 0x20
            @state = LEX_BEFORE_ATTR_NAME
            false
          when 0x2f
            @state = LEX_SELF_CLOSING_START_TAG
            false
          when 0x3e
            @state = LEX_DATA
            emit_current_tag(output)
          when -1
            tokenizer_add_parse_error(ERR_EOF_IN_TAG)
            abandon_current_tag
            emit_eof(output)
          else
            tokenizer_add_parse_error(ERR_MISSING_WHITESPACE_BETWEEN_ATTRIBUTES)
            reconsume_in_state(LEX_BEFORE_ATTR_NAME)
            false
          end
        end

        def handle_self_closing_start_tag_state(c, output)
          case c
          when 0x3e
            @state = LEX_DATA
            @is_self_closing = true
            emit_current_tag(output)
          when -1
            tokenizer_add_parse_error(ERR_EOF_IN_TAG)
            abandon_current_tag
            emit_eof(output)
          else
            tokenizer_add_parse_error(ERR_UNEXPECTED_SOLIDUS_IN_TAG)
            reconsume_in_state(LEX_BEFORE_ATTR_NAME)
            false
          end
        end

        def handle_bogus_comment_state(c, output)
          case c
          when 0x3e
            @state = LEX_DATA
            emit_comment(output)
          when -1
            reconsume_in_state(LEX_DATA)
            emit_comment(output)
          when 0
            tokenizer_add_parse_error(ERR_UNEXPECTED_NULL_CHARACTER)
            append_char_to_temporary_buffer(REPLACEMENT_CHAR)
            false
          else
            append_char_to_temporary_buffer(c)
            if (run = consume_run(RUN_BOGUS_COMMENT))
              @temporary_buffer << run
            end
            false
          end
        end

        DASH_DASH = "--".b.freeze
        DOCTYPE_KW = "DOCTYPE".b.freeze
        CDATA_KW = "[CDATA[".b.freeze
        PUBLIC_KW = "PUBLIC".b.freeze
        SYSTEM_KW = "SYSTEM".b.freeze

        def handle_markup_declaration_open_state(_c, _output)
          if maybe_consume_match(DASH_DASH, true)
            reconsume_in_state(LEX_COMMENT_START)
            return false
          end
          if maybe_consume_match(DOCTYPE_KW, false)
            reconsume_in_state(LEX_DOCTYPE)
            @doc_type_state.name = EMPTY.dup
            @doc_type_state.public_identifier = EMPTY.dup
            @doc_type_state.system_identifier = EMPTY.dup
            return false
          end
          if maybe_consume_match(CDATA_KW, true)
            if @is_adjusted_current_node_foreign
              reconsume_in_state(LEX_CDATA_SECTION)
              @is_in_cdata = true
              reset_token_start_point
            else
              tokenizer_add_token_parse_error(ERR_CDATA_IN_HTML_CONTENT)
              clear_temporary_buffer
              @temporary_buffer << CDATA_KW
              reconsume_in_state(LEX_BOGUS_COMMENT)
            end
            return false
          end
          tokenizer_add_parse_error(ERR_INCORRECTLY_OPENED_COMMENT)
          reconsume_in_state(LEX_BOGUS_COMMENT)
          clear_temporary_buffer
          false
        end

        def handle_comment_start_state(c, output)
          case c
          when 0x2d
            @state = LEX_COMMENT_START_DASH
            false
          when 0x3e
            tokenizer_add_parse_error(ERR_ABRUPT_CLOSING_OF_EMPTY_COMMENT)
            @state = LEX_DATA
            emit_comment(output)
          else
            reconsume_in_state(LEX_COMMENT)
            false
          end
        end

        def handle_comment_start_dash_state(c, output)
          case c
          when 0x2d
            @state = LEX_COMMENT_END
            false
          when 0x3e
            tokenizer_add_parse_error(ERR_ABRUPT_CLOSING_OF_EMPTY_COMMENT)
            @state = LEX_DATA
            emit_comment(output)
          when -1
            tokenizer_add_parse_error(ERR_EOF_IN_COMMENT)
            reconsume_in_state(LEX_DATA)
            emit_comment(output)
          else
            reconsume_in_state(LEX_COMMENT)
            append_char_to_temporary_buffer(0x2d)
            false
          end
        end

        def handle_comment_state(c, output)
          case c
          when 0x3c
            @state = LEX_COMMENT_LT
            append_char_to_temporary_buffer(c)
            false
          when 0x2d
            @state = LEX_COMMENT_END_DASH
            false
          when 0
            tokenizer_add_parse_error(ERR_UNEXPECTED_NULL_CHARACTER)
            append_char_to_temporary_buffer(REPLACEMENT_CHAR)
            false
          when -1
            tokenizer_add_parse_error(ERR_EOF_IN_COMMENT)
            reconsume_in_state(LEX_DATA)
            emit_comment(output)
          else
            append_char_to_temporary_buffer(c)
            if (run = consume_run(RUN_COMMENT))
              @temporary_buffer << run
            end
            false
          end
        end

        def handle_comment_lt_state(c, _output)
          case c
          when 0x21
            @state = LEX_COMMENT_LT_BANG
            append_char_to_temporary_buffer(c)
          when 0x3c
            append_char_to_temporary_buffer(c)
          else
            reconsume_in_state(LEX_COMMENT)
          end
          false
        end

        def handle_comment_lt_bang_state(c, _output)
          if c == 0x2d
            @state = LEX_COMMENT_LT_BANG_DASH
          else
            reconsume_in_state(LEX_COMMENT)
          end
          false
        end

        def handle_comment_lt_bang_dash_state(c, _output)
          if c == 0x2d
            @state = LEX_COMMENT_LT_BANG_DASH_DASH
          else
            reconsume_in_state(LEX_COMMENT_END_DASH)
          end
          false
        end

        def handle_comment_lt_bang_dash_dash_state(c, _output)
          case c
          when 0x3e, -1
            reconsume_in_state(LEX_COMMENT_END)
          else
            tokenizer_add_parse_error(ERR_NESTED_COMMENT)
            reconsume_in_state(LEX_COMMENT_END)
          end
          false
        end

        def handle_comment_end_dash_state(c, output)
          case c
          when 0x2d
            @state = LEX_COMMENT_END
            false
          when -1
            tokenizer_add_parse_error(ERR_EOF_IN_COMMENT)
            @state = LEX_DATA
            emit_comment(output)
          else
            reconsume_in_state(LEX_COMMENT)
            append_char_to_temporary_buffer(0x2d)
            false
          end
        end

        def handle_comment_end_state(c, output)
          case c
          when 0x3e
            @state = LEX_DATA
            emit_comment(output)
          when 0x21
            @state = LEX_COMMENT_END_BANG
            false
          when 0x2d
            append_char_to_temporary_buffer(0x2d)
            false
          when -1
            tokenizer_add_parse_error(ERR_EOF_IN_COMMENT)
            @state = LEX_DATA
            emit_comment(output)
          else
            reconsume_in_state(LEX_COMMENT)
            append_char_to_temporary_buffer(0x2d)
            append_char_to_temporary_buffer(0x2d)
            false
          end
        end

        def handle_comment_end_bang_state(c, output)
          case c
          when 0x2d
            @state = LEX_COMMENT_END_DASH
            append_char_to_temporary_buffer(0x2d)
            append_char_to_temporary_buffer(0x2d)
            append_char_to_temporary_buffer(0x21)
            false
          when 0x3e
            tokenizer_add_parse_error(ERR_INCORRECTLY_CLOSED_COMMENT)
            @state = LEX_DATA
            emit_comment(output)
          when -1
            tokenizer_add_parse_error(ERR_EOF_IN_COMMENT)
            @state = LEX_DATA
            emit_comment(output)
          else
            reconsume_in_state(LEX_COMMENT)
            append_char_to_temporary_buffer(0x2d)
            append_char_to_temporary_buffer(0x2d)
            append_char_to_temporary_buffer(0x21)
            false
          end
        end

        def handle_doctype_state(c, output)
          case c
          when 0x09, 0x0a, 0x0c, 0x20
            @state = LEX_BEFORE_DOCTYPE_NAME
            false
          when 0x3e
            reconsume_in_state(LEX_BEFORE_DOCTYPE_NAME)
            false
          when -1
            tokenizer_add_parse_error(ERR_EOF_IN_DOCTYPE)
            @doc_type_state.force_quirks = true
            reconsume_in_state(LEX_DATA)
            emit_doctype(output)
          else
            tokenizer_add_parse_error(ERR_MISSING_WHITESPACE_BEFORE_DOCTYPE_NAME)
            reconsume_in_state(LEX_BEFORE_DOCTYPE_NAME)
            false
          end
        end

        def handle_before_doctype_name_state(c, output)
          case c
          when 0x09, 0x0a, 0x0c, 0x20
            false
          when 0
            tokenizer_add_parse_error(ERR_UNEXPECTED_NULL_CHARACTER)
            @state = LEX_DOCTYPE_NAME
            append_char_to_temporary_buffer(REPLACEMENT_CHAR)
            false
          when 0x3e
            tokenizer_add_parse_error(ERR_MISSING_DOCTYPE_NAME)
            @state = LEX_DATA
            @doc_type_state.force_quirks = true
            emit_doctype(output)
          when -1
            tokenizer_add_parse_error(ERR_EOF_IN_DOCTYPE)
            @doc_type_state.force_quirks = true
            reconsume_in_state(LEX_DATA)
            emit_doctype(output)
          else
            @state = LEX_DOCTYPE_NAME
            append_char_to_temporary_buffer(Util.ascii_tolower(c))
            false
          end
        end

        def handle_doctype_name_state(c, output)
          case c
          when 0x09, 0x0a, 0x0c, 0x20
            @state = LEX_AFTER_DOCTYPE_NAME
            @doc_type_state.name = finish_temporary_buffer
            false
          when 0x3e
            @state = LEX_DATA
            @doc_type_state.name = finish_temporary_buffer
            emit_doctype(output)
          when 0
            tokenizer_add_parse_error(ERR_UNEXPECTED_NULL_CHARACTER)
            append_char_to_temporary_buffer(REPLACEMENT_CHAR)
            false
          when -1
            tokenizer_add_parse_error(ERR_EOF_IN_DOCTYPE)
            reconsume_in_state(LEX_DATA)
            @doc_type_state.force_quirks = true
            @doc_type_state.name = finish_temporary_buffer
            emit_doctype(output)
          else
            append_char_to_temporary_buffer(Util.ascii_tolower(c))
            false
          end
        end

        def handle_after_doctype_name_state(c, output)
          case c
          when 0x09, 0x0a, 0x0c, 0x20
            false
          when 0x3e
            @state = LEX_DATA
            emit_doctype(output)
          when -1
            tokenizer_add_parse_error(ERR_EOF_IN_DOCTYPE)
            @state = LEX_DATA
            @doc_type_state.force_quirks = true
            emit_doctype(output)
          else
            if maybe_consume_match(PUBLIC_KW, false)
              reconsume_in_state(LEX_AFTER_DOCTYPE_PUBLIC_KEYWORD)
            elsif maybe_consume_match(SYSTEM_KW, false)
              reconsume_in_state(LEX_AFTER_DOCTYPE_SYSTEM_KEYWORD)
            else
              tokenizer_add_parse_error(ERR_INVALID_CHARACTER_SEQUENCE_AFTER_DOCTYPE_NAME)
              reconsume_in_state(LEX_BOGUS_DOCTYPE)
              @doc_type_state.force_quirks = true
            end
            false
          end
        end

        def handle_after_doctype_public_keyword_state(c, output)
          case c
          when 0x09, 0x0a, 0x0c, 0x20
            @state = LEX_BEFORE_DOCTYPE_PUBLIC_ID
            false
          when 0x22
            tokenizer_add_parse_error(ERR_MISSING_WHITESPACE_AFTER_DOCTYPE_PUBLIC_KEYWORD)
            @state = LEX_DOCTYPE_PUBLIC_ID_DOUBLE_QUOTED
            false
          when 0x27
            tokenizer_add_parse_error(ERR_MISSING_WHITESPACE_AFTER_DOCTYPE_PUBLIC_KEYWORD)
            @state = LEX_DOCTYPE_PUBLIC_ID_SINGLE_QUOTED
            false
          when 0x3e
            tokenizer_add_parse_error(ERR_MISSING_DOCTYPE_PUBLIC_IDENTIFIER)
            @state = LEX_DATA
            @doc_type_state.force_quirks = true
            emit_doctype(output)
          when -1
            tokenizer_add_parse_error(ERR_EOF_IN_DOCTYPE)
            reconsume_in_state(LEX_DATA)
            @doc_type_state.force_quirks = true
            emit_doctype(output)
          else
            tokenizer_add_parse_error(ERR_MISSING_QUOTE_BEFORE_DOCTYPE_PUBLIC_IDENTIFIER)
            reconsume_in_state(LEX_BOGUS_DOCTYPE)
            @doc_type_state.force_quirks = true
            false
          end
        end

        def handle_before_doctype_public_id_state(c, output)
          case c
          when 0x09, 0x0a, 0x0c, 0x20
            false
          when 0x22
            @state = LEX_DOCTYPE_PUBLIC_ID_DOUBLE_QUOTED
            false
          when 0x27
            @state = LEX_DOCTYPE_PUBLIC_ID_SINGLE_QUOTED
            false
          when 0x3e
            tokenizer_add_parse_error(ERR_MISSING_DOCTYPE_PUBLIC_IDENTIFIER)
            @state = LEX_DATA
            @doc_type_state.force_quirks = true
            emit_doctype(output)
          when -1
            tokenizer_add_parse_error(ERR_EOF_IN_DOCTYPE)
            reconsume_in_state(LEX_DATA)
            @doc_type_state.force_quirks = true
            emit_doctype(output)
          else
            tokenizer_add_parse_error(ERR_MISSING_QUOTE_BEFORE_DOCTYPE_PUBLIC_IDENTIFIER)
            reconsume_in_state(LEX_BOGUS_DOCTYPE)
            @doc_type_state.force_quirks = true
            false
          end
        end

        def doctype_public_id_quoted_state(c, output, quote)
          case c
          when quote
            @state = LEX_AFTER_DOCTYPE_PUBLIC_ID
            finish_doctype_public_id
            false
          when 0
            tokenizer_add_parse_error(ERR_UNEXPECTED_NULL_CHARACTER)
            append_char_to_temporary_buffer(REPLACEMENT_CHAR)
            false
          when 0x3e
            tokenizer_add_parse_error(ERR_ABRUPT_DOCTYPE_PUBLIC_IDENTIFIER)
            @state = LEX_DATA
            @doc_type_state.force_quirks = true
            finish_doctype_public_id
            emit_doctype(output)
          when -1
            tokenizer_add_parse_error(ERR_EOF_IN_DOCTYPE)
            reconsume_in_state(LEX_DATA)
            @doc_type_state.force_quirks = true
            finish_doctype_public_id
            emit_doctype(output)
          else
            append_char_to_temporary_buffer(c)
            false
          end
        end

        def handle_doctype_public_id_double_quoted_state(c, output)
          doctype_public_id_quoted_state(c, output, 0x22)
        end

        def handle_doctype_public_id_single_quoted_state(c, output)
          doctype_public_id_quoted_state(c, output, 0x27)
        end

        def handle_after_doctype_public_id_state(c, output)
          case c
          when 0x09, 0x0a, 0x0c, 0x20
            @state = LEX_BETWEEN_DOCTYPE_PUBLIC_SYSTEM_ID
            false
          when 0x3e
            @state = LEX_DATA
            emit_doctype(output)
          when 0x22
            tokenizer_add_parse_error(ERR_MISSING_WHITESPACE_BETWEEN_DOCTYPE_PUBLIC_AND_SYSTEM_IDENTIFIERS)
            @state = LEX_DOCTYPE_SYSTEM_ID_DOUBLE_QUOTED
            false
          when 0x27
            tokenizer_add_parse_error(ERR_MISSING_WHITESPACE_BETWEEN_DOCTYPE_PUBLIC_AND_SYSTEM_IDENTIFIERS)
            @state = LEX_DOCTYPE_SYSTEM_ID_SINGLE_QUOTED
            false
          when -1
            tokenizer_add_parse_error(ERR_EOF_IN_DOCTYPE)
            reconsume_in_state(LEX_DATA)
            @doc_type_state.force_quirks = true
            emit_doctype(output)
          else
            tokenizer_add_parse_error(ERR_MISSING_QUOTE_BEFORE_DOCTYPE_SYSTEM_IDENTIFIER)
            reconsume_in_state(LEX_BOGUS_DOCTYPE)
            @doc_type_state.force_quirks = true
            false
          end
        end

        def handle_between_doctype_public_system_id_state(c, output)
          case c
          when 0x09, 0x0a, 0x0c, 0x20
            false
          when 0x3e
            @state = LEX_DATA
            emit_doctype(output)
          when 0x22
            @state = LEX_DOCTYPE_SYSTEM_ID_DOUBLE_QUOTED
            false
          when 0x27
            @state = LEX_DOCTYPE_SYSTEM_ID_SINGLE_QUOTED
            false
          when -1
            tokenizer_add_parse_error(ERR_EOF_IN_DOCTYPE)
            reconsume_in_state(LEX_DATA)
            @doc_type_state.force_quirks = true
            emit_doctype(output)
          else
            tokenizer_add_parse_error(ERR_MISSING_QUOTE_BEFORE_DOCTYPE_SYSTEM_IDENTIFIER)
            reconsume_in_state(LEX_BOGUS_DOCTYPE)
            @doc_type_state.force_quirks = true
            false
          end
        end

        def handle_after_doctype_system_keyword_state(c, output)
          case c
          when 0x09, 0x0a, 0x0c, 0x20
            @state = LEX_BEFORE_DOCTYPE_SYSTEM_ID
            false
          when 0x22
            tokenizer_add_parse_error(ERR_MISSING_WHITESPACE_AFTER_DOCTYPE_SYSTEM_KEYWORD)
            @state = LEX_DOCTYPE_SYSTEM_ID_DOUBLE_QUOTED
            false
          when 0x27
            tokenizer_add_parse_error(ERR_MISSING_WHITESPACE_AFTER_DOCTYPE_SYSTEM_KEYWORD)
            @state = LEX_DOCTYPE_SYSTEM_ID_SINGLE_QUOTED
            false
          when 0x3e
            tokenizer_add_parse_error(ERR_MISSING_DOCTYPE_SYSTEM_IDENTIFIER)
            @state = LEX_DATA
            @doc_type_state.force_quirks = true
            emit_doctype(output)
          when -1
            tokenizer_add_parse_error(ERR_EOF_IN_DOCTYPE)
            reconsume_in_state(LEX_DATA)
            @doc_type_state.force_quirks = true
            emit_doctype(output)
          else
            tokenizer_add_parse_error(ERR_MISSING_QUOTE_BEFORE_DOCTYPE_SYSTEM_IDENTIFIER)
            reconsume_in_state(LEX_BOGUS_DOCTYPE)
            @doc_type_state.force_quirks = true
            false
          end
        end

        def handle_before_doctype_system_id_state(c, output)
          case c
          when 0x09, 0x0a, 0x0c, 0x20
            false
          when 0x22
            @state = LEX_DOCTYPE_SYSTEM_ID_DOUBLE_QUOTED
            false
          when 0x27
            @state = LEX_DOCTYPE_SYSTEM_ID_SINGLE_QUOTED
            false
          when 0x3e
            tokenizer_add_parse_error(ERR_MISSING_DOCTYPE_SYSTEM_IDENTIFIER)
            @state = LEX_DATA
            @doc_type_state.force_quirks = true
            emit_doctype(output)
          when -1
            tokenizer_add_parse_error(ERR_EOF_IN_DOCTYPE)
            reconsume_in_state(LEX_DATA)
            @doc_type_state.force_quirks = true
            emit_doctype(output)
          else
            tokenizer_add_parse_error(ERR_MISSING_QUOTE_BEFORE_DOCTYPE_SYSTEM_IDENTIFIER)
            reconsume_in_state(LEX_BOGUS_DOCTYPE)
            @doc_type_state.force_quirks = true
            false
          end
        end

        def doctype_system_id_quoted_state(c, output, quote)
          case c
          when quote
            @state = LEX_AFTER_DOCTYPE_SYSTEM_ID
            finish_doctype_system_id
            false
          when 0
            tokenizer_add_parse_error(ERR_UNEXPECTED_NULL_CHARACTER)
            append_char_to_temporary_buffer(REPLACEMENT_CHAR)
            false
          when 0x3e
            tokenizer_add_parse_error(ERR_ABRUPT_DOCTYPE_SYSTEM_IDENTIFIER)
            @state = LEX_DATA
            @doc_type_state.force_quirks = true
            finish_doctype_system_id
            emit_doctype(output)
          when -1
            tokenizer_add_parse_error(ERR_EOF_IN_DOCTYPE)
            reconsume_in_state(LEX_DATA)
            @doc_type_state.force_quirks = true
            finish_doctype_system_id
            emit_doctype(output)
          else
            append_char_to_temporary_buffer(c)
            false
          end
        end

        def handle_doctype_system_id_double_quoted_state(c, output)
          doctype_system_id_quoted_state(c, output, 0x22)
        end

        def handle_doctype_system_id_single_quoted_state(c, output)
          doctype_system_id_quoted_state(c, output, 0x27)
        end

        def handle_after_doctype_system_id_state(c, output)
          case c
          when 0x09, 0x0a, 0x0c, 0x20
            false
          when 0x3e
            @state = LEX_DATA
            emit_doctype(output)
          when -1
            tokenizer_add_parse_error(ERR_EOF_IN_DOCTYPE)
            reconsume_in_state(LEX_DATA)
            @doc_type_state.force_quirks = true
            emit_doctype(output)
          else
            tokenizer_add_parse_error(ERR_UNEXPECTED_CHARACTER_AFTER_DOCTYPE_SYSTEM_IDENTIFIER)
            reconsume_in_state(LEX_BOGUS_DOCTYPE)
            false
          end
        end

        def handle_bogus_doctype_state(c, output)
          case c
          when 0x3e
            @state = LEX_DATA
            emit_doctype(output)
          when 0
            tokenizer_add_parse_error(ERR_UNEXPECTED_NULL_CHARACTER)
            false
          when -1
            reconsume_in_state(LEX_DATA)
            emit_doctype(output)
          else
            false
          end
        end

        def handle_cdata_section_state(c, output)
          case c
          when 0x5d # ]
            @state = LEX_CDATA_SECTION_BRACKET
            set_mark
            false
          when -1
            tokenizer_add_parse_error(ERR_EOF_IN_CDATA)
            emit_eof(output)
          else
            emit_char(c, output)
          end
        end

        def handle_cdata_section_bracket_state(c, output)
          if c == 0x5d
            @state = LEX_CDATA_SECTION_END
            false
          else
            reconsume_in_state(LEX_CDATA_SECTION)
            emit_from_mark(output)
          end
        end

        def handle_cdata_section_end_state(c, output)
          case c
          when 0x5d
            result = emit_from_mark(output)
            @resume_pos = nil
            set_mark
            @state = LEX_CDATA_SECTION
            result
          when 0x3e
            iter_next
            reset_token_start_point
            reconsume_in_state(LEX_DATA)
            @is_in_cdata = false
            false
          else
            reconsume_in_state(LEX_CDATA_SECTION)
            emit_from_mark(output)
          end
        end

        def handle_character_reference_state(c, output)
          if Util.ascii_isalnum(c)
            reconsume_in_state(LEX_NAMED_CHARACTER_REFERENCE)
            return false
          end
          if c == 0x23 # #
            @state = LEX_NUMERIC_CHARACTER_REFERENCE
            return false
          end
          reconsume_in_state(@return_state)
          flush_code_points_consumed_as_character_reference(output)
        end

        def handle_named_character_reference_state(_c, output)
          cur = @start
          match = Util.match_named_char_ref(@input, cur, @end)
          if match
            size, cps = match
            if cps.is_a?(Array)
              cp0, cp1 = cps
            else
              cp0 = cps
              cp1 = NO_CHAR
            end
            size.times { iter_next }
            nxt = @current
            reconsume_in_state(@return_state)
            semicolon = @input.getbyte(cur + size - 1) == 0x3b
            if character_reference_part_of_attribute && !semicolon &&
                (nxt == 0x3d || Util.ascii_isalnum(nxt))
              return flush_code_points_consumed_as_character_reference(output)
            end
            unless semicolon
              tokenizer_add_char_ref_error(ERR_MISSING_SEMICOLON_AFTER_CHARACTER_REFERENCE, -1)
            end
            reconsume_in_state(@return_state)
            return flush_char_ref(cp0, cp1, output)
          end
          reconsume_in_state(LEX_AMBIGUOUS_AMPERSAND)
          flush_code_points_consumed_as_character_reference(output)
        end

        def handle_ambiguous_ampersand_state(c, output)
          if Util.ascii_isalnum(c)
            if character_reference_part_of_attribute
              append_char_to_tag_buffer(c, true)
              return false
            end
            return emit_char(c, output)
          end
          if c == 0x3b
            tokenizer_add_char_ref_error(ERR_UNKNOWN_NAMED_CHARACTER_REFERENCE, -1)
          end
          reconsume_in_state(@return_state)
          false
        end

        def handle_numeric_character_reference_state(c, _output)
          @character_reference_code = 0
          if c == 0x78 || c == 0x58 # x X
            @state = LEX_HEXADECIMAL_CHARACTER_REFERENCE_START
          else
            reconsume_in_state(LEX_DECIMAL_CHARACTER_REFERENCE_START)
          end
          false
        end

        def handle_hexadecimal_character_reference_start_state(c, output)
          if c >= 0 && c < 128 && ASCII_XDIGIT[c]
            reconsume_in_state(LEX_HEXADECIMAL_CHARACTER_REFERENCE)
            return false
          end
          tokenizer_add_char_ref_error(ERR_ABSENCE_OF_DIGITS_IN_NUMERIC_CHARACTER_REFERENCE, -1)
          reconsume_in_state(@return_state)
          flush_code_points_consumed_as_character_reference(output)
        end

        def handle_decimal_character_reference_start_state(c, output)
          if c >= 0x30 && c <= 0x39
            reconsume_in_state(LEX_DECIMAL_CHARACTER_REFERENCE)
            return false
          end
          tokenizer_add_char_ref_error(ERR_ABSENCE_OF_DIGITS_IN_NUMERIC_CHARACTER_REFERENCE, -1)
          reconsume_in_state(@return_state)
          flush_code_points_consumed_as_character_reference(output)
        end

        def handle_hexadecimal_character_reference_state(c, _output)
          digit = if c >= 0x30 && c <= 0x39
            c - 0x30
          elsif c >= 0x41 && c <= 0x46
            c - 0x37
          elsif c >= 0x61 && c <= 0x66
            c - 0x57
          end
          if digit
            code = @character_reference_code * 16 + digit
            code = MAX_CHAR + 1 if code > MAX_CHAR
            @character_reference_code = code
            return false
          end
          if c == 0x3b
            @state = LEX_NUMERIC_CHARACTER_REFERENCE_END
            return false
          end
          tokenizer_add_char_ref_error(ERR_MISSING_SEMICOLON_AFTER_CHARACTER_REFERENCE, @character_reference_code)
          reconsume_in_state(LEX_NUMERIC_CHARACTER_REFERENCE_END)
          false
        end

        def handle_decimal_character_reference_state(c, _output)
          if c >= 0x30 && c <= 0x39
            code = @character_reference_code * 10 + (c - 0x30)
            code = MAX_CHAR + 1 if code > MAX_CHAR
            @character_reference_code = code
            return false
          end
          if c == 0x3b
            @state = LEX_NUMERIC_CHARACTER_REFERENCE_END
            return false
          end
          tokenizer_add_char_ref_error(ERR_MISSING_SEMICOLON_AFTER_CHARACTER_REFERENCE, @character_reference_code)
          reconsume_in_state(LEX_NUMERIC_CHARACTER_REFERENCE_END)
          false
        end

        C1_REPLACEMENTS = {
          0x80 => 0x20AC, 0x82 => 0x201A, 0x83 => 0x0192, 0x84 => 0x201E, 0x85 => 0x2026,
          0x86 => 0x2020, 0x87 => 0x2021, 0x88 => 0x02C6, 0x89 => 0x2030, 0x8A => 0x0160,
          0x8B => 0x2039, 0x8C => 0x0152, 0x8E => 0x017D, 0x91 => 0x2018, 0x92 => 0x2019,
          0x93 => 0x201C, 0x94 => 0x201D, 0x95 => 0x2022, 0x96 => 0x2013, 0x97 => 0x2014,
          0x98 => 0x02DC, 0x99 => 0x2122, 0x9A => 0x0161, 0x9B => 0x203A, 0x9C => 0x0153,
          0x9E => 0x017E, 0x9F => 0x0178,
        }.freeze

        def handle_numeric_character_reference_end_state(_c, output)
          c = @character_reference_code
          if c == 0
            tokenizer_add_char_ref_error(ERR_NULL_CHARACTER_REFERENCE, c)
            c = REPLACEMENT_CHAR
          elsif c > MAX_CHAR
            tokenizer_add_char_ref_error(ERR_CHARACTER_REFERENCE_OUTSIDE_UNICODE_RANGE, c)
            c = REPLACEMENT_CHAR
          elsif c >= 0xD800 && c <= 0xDFFF
            tokenizer_add_char_ref_error(ERR_SURROGATE_CHARACTER_REFERENCE, c)
            c = REPLACEMENT_CHAR
          elsif (c >= 0xFDD0 && c <= 0xFDEF) || (c & 0xFFFF) >= 0xFFFE
            tokenizer_add_char_ref_error(ERR_NONCHARACTER_CHARACTER_REFERENCE, c)
          elsif c == 0x0D || ((c < 0x1F || (c >= 0x7F && c <= 0x9F)) && !Util.ascii_isspace(c))
            tokenizer_add_char_ref_error(ERR_CONTROL_CHARACTER_REFERENCE, c)
            c = C1_REPLACEMENTS.fetch(c, c)
          end
          reconsume_in_state(@return_state)
          flush_char_ref(c, NO_CHAR, output)
        end

        HANDLERS = [
          :handle_data_state,
          :handle_rcdata_state,
          :handle_rawtext_state,
          :handle_script_data_state,
          :handle_plaintext_state,
          :handle_tag_open_state,
          :handle_end_tag_open_state,
          :handle_tag_name_state,
          :handle_rcdata_lt_state,
          :handle_rcdata_end_tag_open_state,
          :handle_rcdata_end_tag_name_state,
          :handle_rawtext_lt_state,
          :handle_rawtext_end_tag_open_state,
          :handle_rawtext_end_tag_name_state,
          :handle_script_data_lt_state,
          :handle_script_data_end_tag_open_state,
          :handle_script_data_end_tag_name_state,
          :handle_script_data_escaped_start_state,
          :handle_script_data_escaped_start_dash_state,
          :handle_script_data_escaped_state,
          :handle_script_data_escaped_dash_state,
          :handle_script_data_escaped_dash_dash_state,
          :handle_script_data_escaped_lt_state,
          :handle_script_data_escaped_end_tag_open_state,
          :handle_script_data_escaped_end_tag_name_state,
          :handle_script_data_double_escaped_start_state,
          :handle_script_data_double_escaped_state,
          :handle_script_data_double_escaped_dash_state,
          :handle_script_data_double_escaped_dash_dash_state,
          :handle_script_data_double_escaped_lt_state,
          :handle_script_data_double_escaped_end_state,
          :handle_before_attr_name_state,
          :handle_attr_name_state,
          :handle_after_attr_name_state,
          :handle_before_attr_value_state,
          :handle_attr_value_double_quoted_state,
          :handle_attr_value_single_quoted_state,
          :handle_attr_value_unquoted_state,
          :handle_after_attr_value_quoted_state,
          :handle_self_closing_start_tag_state,
          :handle_bogus_comment_state,
          :handle_markup_declaration_open_state,
          :handle_comment_start_state,
          :handle_comment_start_dash_state,
          :handle_comment_state,
          :handle_comment_lt_state,
          :handle_comment_lt_bang_state,
          :handle_comment_lt_bang_dash_state,
          :handle_comment_lt_bang_dash_dash_state,
          :handle_comment_end_dash_state,
          :handle_comment_end_state,
          :handle_comment_end_bang_state,
          :handle_doctype_state,
          :handle_before_doctype_name_state,
          :handle_doctype_name_state,
          :handle_after_doctype_name_state,
          :handle_after_doctype_public_keyword_state,
          :handle_before_doctype_public_id_state,
          :handle_doctype_public_id_double_quoted_state,
          :handle_doctype_public_id_single_quoted_state,
          :handle_after_doctype_public_id_state,
          :handle_between_doctype_public_system_id_state,
          :handle_after_doctype_system_keyword_state,
          :handle_before_doctype_system_id_state,
          :handle_doctype_system_id_double_quoted_state,
          :handle_doctype_system_id_single_quoted_state,
          :handle_after_doctype_system_id_state,
          :handle_bogus_doctype_state,
          :handle_cdata_section_state,
          :handle_cdata_section_bracket_state,
          :handle_cdata_section_end_state,
          :handle_character_reference_state,
          :handle_named_character_reference_state,
          :handle_ambiguous_ampersand_state,
          :handle_numeric_character_reference_state,
          :handle_hexadecimal_character_reference_start_state,
          :handle_decimal_character_reference_start_state,
          :handle_hexadecimal_character_reference_state,
          :handle_decimal_character_reference_state,
          :handle_numeric_character_reference_end_state,
        ].freeze

        # ---- fast path (not in gumbo) -------------------------------------------------------
        #
        # A run of "plain" characters in one of the text states would be emitted one character
        # token at a time, each one advancing the input by one code point and producing no
        # errors. scan_text_run consumes such a run in one go, leaving the tokenizer in exactly
        # the state it would have been in after emitting the last character of the run, and
        # returns the run's bytes (or nil). The parser only calls it when it knows that each of
        # these character tokens would simply be appended to the pending text node.

        # UTF-8 sequences of 2 or 3 bytes that decode without any error: no C1 controls, no
        # surrogates, no noncharacters.
        SAFE_MB = "(?:\\xC2[\\xA0-\\xBF]|[\\xC3-\\xDF][\\x80-\\xBF]|\\xE0[\\xA0-\\xBF][\\x80-\\xBF]|" \
          "[\\xE1-\\xEC\\xEE][\\x80-\\xBF][\\x80-\\xBF]|\\xED[\\x80-\\x9F][\\x80-\\xBF]|" \
          "\\xEF(?:[\\x80-\\xB6][\\x80-\\xBF]|\\xB7[\\x80-\\x8F\\xB0-\\xBF]|[\\xB8-\\xBE][\\x80-\\xBF]|\\xBF[\\x80-\\xBD]))"
        RUN_DATA = Regexp.new("(?:[\\t\\n\\x0C\\x20-\\x25\\x27-\\x3B\\x3D-\\x7E]++|#{SAFE_MB})+".b, Regexp::NOENCODING)
        RUN_RAWTEXT = Regexp.new("(?:[\\t\\n\\x0C\\x20-\\x3B\\x3D-\\x7E]++|#{SAFE_MB})+".b, Regexp::NOENCODING)
        RUN_PLAINTEXT = Regexp.new("(?:[\\t\\n\\x0C\\x20-\\x7E]++|#{SAFE_MB})+".b, Regexp::NOENCODING)
        RUN_RES = [RUN_DATA, RUN_DATA, RUN_RAWTEXT, RUN_RAWTEXT, RUN_PLAINTEXT].freeze # by LEX_ state
        NON_WS_RE = /[^\t\n\x0C ]/n
        CONT_BYTES = "\x80-\xBF".b.freeze

        # Moves the iterator over `run` (the bytes starting at the current character), updating the
        # position as utf8iterator_next would have one code point at a time, and reads the
        # character that follows. The run must consist of error-free characters, none of them \r.
        def advance_over(run)
          len = run.bytesize
          if run.ascii_only? && !run.include?("\t")
            # (the common case: one column per byte)
            nl = run.rindex("\n")
            if nl
              @line += run.count("\n")
              @column = len - nl
            else
              @column += len
            end
            @offset += len
            @start += len
            read_char
            return
          end
          nl = run.rindex("\n")
          if nl
            @line += run.count("\n")
            column = 1
            seg = run.byteslice(nl + 1, len - nl - 1)
          else
            column = @column
            seg = run
          end
          if seg.include?("\t")
            tab_stop = @tab_stop
            seg.each_byte do |b|
              if b == 0x09
                column = ((column / tab_stop) + 1) * tab_stop
              elsif (b & 0xC0) != 0x80
                column += 1
              end
            end
          elsif seg.ascii_only?
            column += seg.bytesize
          else
            column += seg.bytesize - seg.count(CONT_BYTES)
          end
          @column = column
          @offset += len
          @start += len
          read_char
        end

        # Used by the states whose "anything else" branch just appends the character to a buffer:
        # after the current character has been handled, consumes the following run of characters
        # matching `re` (which must only match characters that go to that same branch without
        # errors) and returns it; the iterator is left on the character after the run, flagged
        # for reconsumption so that the state machine continues from there. Returns nil if the
        # run is empty.
        def consume_run(re)
          nxt = @start + @width
          return nil if nxt >= @end

          ss = (@scanner ||= StringScanner.new(@input))
          ss.pos = nxt
          len = ss.skip(re)
          return nil if len.nil? || len == 0

          iter_next
          run = @input.byteslice(nxt, len)
          advance_over(run)
          @reconsume = true
          run
        end

        RUN_TAG_NAME = Regexp.new("(?:[\\x21-\\x2E\\x30-\\x3D\\x3F-\\x7E]++|#{SAFE_MB})+".b, Regexp::NOENCODING)
        RUN_ATTR_NAME = Regexp.new("(?:[\\x21\\x23-\\x26\\x28-\\x2E\\x30-\\x3B\\x3F-\\x7E]++|#{SAFE_MB})+".b, Regexp::NOENCODING)
        RUN_ATTR_VALUE_DQ = Regexp.new("(?:[\\t\\n\\x0C\\x20\\x21\\x23-\\x25\\x27-\\x7E]++|#{SAFE_MB})+".b, Regexp::NOENCODING)
        RUN_ATTR_VALUE_SQ = Regexp.new("(?:[\\t\\n\\x0C\\x20-\\x25\\x28-\\x7E]++|#{SAFE_MB})+".b, Regexp::NOENCODING)
        RUN_ATTR_VALUE_UQ = Regexp.new("(?:[\\x21\\x23-\\x25\\x28-\\x3B\\x3F-\\x5F\\x61-\\x7E]++|#{SAFE_MB})+".b, Regexp::NOENCODING)
        RUN_COMMENT = Regexp.new("(?:[\\t\\n\\x0C\\x20-\\x2C\\x2E-\\x3B\\x3D-\\x7E]++|#{SAFE_MB})+".b, Regexp::NOENCODING)
        RUN_BOGUS_COMMENT = Regexp.new("(?:[\\t\\n\\x0C\\x20-\\x3D\\x3F-\\x7E]++|#{SAFE_MB})+".b, Regexp::NOENCODING)

        def scan_text_run
          return nil unless @state <= LEX_PLAINTEXT && @buffered_emit_char == NO_CHAR && @resume_pos.nil? &&
            !@is_in_cdata

          start = @start
          return nil if start >= @end

          ss = (@scanner ||= StringScanner.new(@input))
          ss.pos = start
          len = ss.skip(RUN_RES[@state])
          return nil if len.nil? || len == 0

          run = @input.byteslice(start, len)
          advance_over(run)
          reset_token_start_point
          run
        end

        # A whole tag that the tag states would tokenize without any error, character reference,
        # carriage return or input-dependent branching: "<name attr=value ...>" / "</name>".
        FT_WS = "[\\t\\n\\f ]"
        FT_TNAME = "[A-Za-z][\\x21-\\x2E\\x30-\\x3D\\x3F-\\x7E]*+"
        FT_ANAME = "[\\x21\\x23-\\x26\\x28-\\x2E\\x30-\\x3B\\x3F-\\x7E]++"
        FT_DQV = "(?:[\\t\\n\\x0C\\x20\\x21\\x23-\\x25\\x27-\\x7E]++|#{SAFE_MB})*+"
        FT_SQV = "(?:[\\t\\n\\x0C\\x20-\\x25\\x28-\\x7E]++|#{SAFE_MB})*+"
        FT_UQV = "(?:[\\x21\\x23-\\x25\\x28-\\x3B\\x3F-\\x5F\\x61-\\x7E]++|#{SAFE_MB})++"
        FT_ATTR = "#{FT_WS}++(#{FT_ANAME})(?:=(?:\"(#{FT_DQV})\"|'(#{FT_SQV})'|(#{FT_UQV})))?"
        FAST_ATTR = Regexp.new(FT_ATTR.b, Regexp::NOENCODING)
        UPPER = /[A-Z]/n
        NL = "\n".b.freeze
        TAB = "\t".b.freeze
        FAST_TAG_NAME = Regexp.new(FT_TNAME.b, Regexp::NOENCODING)
        FAST_TAG_END = Regexp.new("#{FT_WS}*+>".b, Regexp::NOENCODING)
        FAST_TAG_SELF_CLOSING_END = Regexp.new("#{FT_WS}*+/>".b, Regexp::NOENCODING)

        # Tokenizes such a tag starting at the current '<' (in the data state) in one go, leaving
        # the tokenizer exactly as the character-by-character state machine would. Returns false
        # (without touching anything) when the tag isn't that simple.
        def fast_tag(output)
          start = @start
          ss = (@scanner ||= StringScanner.new(@input))
          attrs = nil
          non_ascii = false
          if @input.getbyte(start + 1) == 0x2F
            ss.pos = start + 2
            return false unless ss.skip(FAST_TAG_NAME)

            name = ss.matched
            return false unless @input.getbyte(ss.pos) == 0x3e

            is_start = false
            self_closing = false
            reset_rel = ss.pos - start
            len = reset_rel + 1
          else
            ss.pos = start + 1
            return false unless ss.skip(FAST_TAG_NAME)

            name = ss.matched
            max_attributes = @parser.max_attributes
            attrs = []
            while ss.skip(FAST_ATTR)
              aname = ss[1]
              orig_len = aname.bytesize
              aname.downcase! if aname.match?(UPPER)
              return false if max_attributes >= 0 && attrs.length >= max_attributes
              return false if attrs.any? { |a| a.name == aname }

              value = ss[2] || ss[3] || ss[4]
              if value
                non_ascii = true unless value.ascii_only?
              else
                value = EMPTY.dup
              end
              attrs << Attribute.new(aname, value, orig_len)
            end
            reset_rel = ss.pos - start
            if (tail = ss.skip(FAST_TAG_END))
              self_closing = false
            elsif (tail = ss.skip(FAST_TAG_SELF_CLOSING_END))
              self_closing = true
            else
              return false
            end
            is_start = true
            len = reset_rel + tail
          end
          name.downcase! if name.match?(UPPER)

          # <: set_mark; start_new_tag; the name and attributes; the last
          # reinitialize_tag_buffer/reset_tag_buffer_start_point happens at reset_rel
          iter_mark
          # (@next_nl/@next_tab: the next "\n"/"\t" at or after some position <= start, found
          # without rescanning; names are ASCII and non-ASCII values were noted above)
          nl = @next_nl
          nl = @next_nl = @input.byteindex(NL, start) || @end if nl.nil? || nl < start
          tab = @next_tab
          tab = @next_tab = @input.byteindex(TAB, start) || @end if tab.nil? || tab < start
          if !non_ascii && nl >= start + len && tab >= start + len
            # one column per byte: move straight to the reset point, then onto the '>'
            @column += reset_rel
            @offset += reset_rel
            @start = start + reset_rel
            reset_tag_buffer_start_point
            rest = len - 1 - reset_rel
            @column += rest
            @offset += rest
            @start += rest
            @current = 0x3e
            @width = 1
          else
            advance_over(@input.byteslice(start, reset_rel))
            reset_tag_buffer_start_point
            advance_over(@input.byteslice(start + reset_rel, len - 1 - reset_rel)) if len - 1 > reset_rel
          end
          @tag = tag = Util.tagn_enum(name)
          @drop_next_attr_value = false
          @is_start_tag = is_start
          @is_self_closing = self_closing
          # emit_current_tag
          if is_start
            output.type = TOKEN_START_TAG
            output.tag = tag
            output.name = tag == TAG_UNKNOWN ? name : @tag_name
            output.attributes = attrs
            output.is_self_closing = self_closing
            @last_start_tag = tag
          else
            output.type = TOKEN_END_TAG
            output.tag = tag
            output.name = tag == TAG_UNKNOWN ? name : @tag_name
          end
          @tag_name = nil
          @tag_attributes = nil
          @tag_buffer.clear # (a fresh buffer in emit_current_tag; this one is never shared)
          @state = LEX_DATA
          finish_token(output)
          true
        end

        # gumbo_lex
        def lex(output)
          if @buffered_emit_char != NO_CHAR
            @reconsume = true
            emit_char(@buffered_emit_char, output)
            @reconsume = false
            @buffered_emit_char = NO_CHAR
            return
          end

          return if maybe_emit_from_mark(output)

          handlers = HANDLERS
          while true
            return if @state == LEX_DATA && @current == 0x3c && fast_tag(output)

            result = __send__(handlers[@state], @current, output)
            should_advance = !@reconsume
            @reconsume = false
            return if result

            iter_next if should_advance
          end
        end
      end
    end
  end
end
