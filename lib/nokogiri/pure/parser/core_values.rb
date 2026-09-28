# frozen_string_literal: true

module Nokogiri
  module Pure
    module Parser
      class Ctxt
        ATT_RUN = {
          [0x22, false] => /[^"&<\x00-\x1F\u0080-\u{10FFFF}]+/,
          [0x27, false] => /[^'&<\x00-\x1F\u0080-\u{10FFFF}]+/,
          [0x22, true] => /[^"&< \x00-\x1F\u0080-\u{10FFFF}]+/,
          [0x27, true] => /[^'&< \x00-\x1F\u0080-\u{10FFFF}]+/,
        }.freeze
        MB_RUN_RE = /[\u0080-￼\u{10000}-\u{10FFFF}]+/

        # xmlUTF8MultibyteLen at the current position (buffer is valid UTF-8): returns the byte
        # length, or 0 for a replaced invalid byte.
        def utf8_multibyte_len(errmsg)
          v, l = decode_at(@cur)
          if v == REPLACEMENT_CHAR && bad_byte_at(@cur)
            report_bad_byte
            return 0
          end
          fatal_err_msg(ErrCode::ERR_INVALID_CHAR, errmsg) if v == 0xFFFE || v == 0xFFFF
          l
        end

        # ---- entity values -----------------------------------------------------------------------

        # xmlExpandPEsInEntityValue
        def expand_pes_in_entity_value(buf, str, depth)
          max_depth = option?(PARSE_HUGE) ? 40 : 20
          return if str.nil?

          depth += 1
          if depth > max_depth
            fatal_err_msg(ErrCode::ERR_RESOURCE_LIMIT, "Maximum entity nesting depth exceeded")
            return
          end
          s = str.b
          len = s.bytesize
          pos = 0
          chunk = 0
          while pos < len && !stopped?
            c = s.getbyte(pos)
            if c == 0xEF && @entity_value_bad && s.getbyte(pos + 1) == 0xBF && s.getbyte(pos + 2) == 0xBD &&
                @entity_value_bad.include?(pos)
              report_bad_byte
              buf.add(s.byteslice(chunk, pos - chunk).force_encoding(Encoding::UTF_8)) if chunk < pos
              buf.add("\uFFFD")
              pos += 3
              chunk = pos
            elsif c >= 0x80
              l = utf8_len_in(s, pos)
              if l == 0
                buf.add(s.byteslice(chunk, pos - chunk).force_encoding(Encoding::UTF_8)) if chunk < pos
                buf.add("�")
                pos += 1
                chunk = pos
              else
                pos += l
              end
            elsif c == 0x26
              if s.getbyte(pos + 1) == 0x23
                buf.add(s.byteslice(chunk, pos - chunk).force_encoding(Encoding::UTF_8)) if chunk < pos
                c, pos = parse_string_char_ref(s, pos)
                return if c == 0

                buf.add_char(c)
                chunk = pos
              else
                pos += 1
                name, pos = parse_string_name(s, pos)
                if name.nil? || s.getbyte(pos) != 0x3B
                  pos += 1
                  fatal_err_msg(ErrCode::ERR_ENTITY_CHAR_ERROR,
                    "EntityValue: '&' forbidden except for entities references\n")
                  return
                end
                pos += 1
              end
            elsif c == 0x25
              buf.add(s.byteslice(chunk, pos - chunk).force_encoding(Encoding::UTF_8)) if chunk < pos
              ent, pos = parse_string_pe_reference(s, pos)
              return if ent.nil?

              unless external?
                fatal_err(ErrCode::ERR_ENTITY_PE_INTERNAL)
                return
              end
              if ent.content.nil?
                if !option?(PARSE_NO_XXE) && (@replace_entities != 0 || @validate != 0)
                  load_entity_content(ent)
                else
                  warning_msg(ErrCode::ERR_ENTITY_PROCESSING,
                    "not validating will not read content for PE entity #{ent.name}\n", ent.name, nil)
                end
              end
              return if parser_entity_check(ent.length) != 0

              if (ent.flags & ENT_EXPANDING) != 0
                fatal_err(ErrCode::ERR_ENTITY_LOOP)
                halt
                return
              end
              ent.flags |= ENT_EXPANDING
              expand_pes_in_entity_value(buf, ent.content, depth)
              ent.flags &= ~ENT_EXPANDING
              chunk = pos
            else
              if !Chars.byte_char?(c)
                fatal_err_msg(ErrCode::ERR_INVALID_CHAR, "invalid character in entity value\n")
                buf.add(s.byteslice(chunk, pos - chunk).force_encoding(Encoding::UTF_8)) if chunk < pos
                buf.add("�")
                pos += 1
                chunk = pos
              else
                pos += 1
              end
            end
          end
          buf.add(s.byteslice(chunk, pos - chunk).force_encoding(Encoding::UTF_8)) if chunk < pos
        end

        # xmlUTF8MultibyteLen on a string
        def utf8_len_in(s, pos)
          c = s.getbyte(pos)
          c1 = s.getbyte(pos + 1) || 0
          bad = lambda do
            report_bad_byte
            return 0
          end
          bad.call if (c1 & 0xC0) != 0x80
          if c < 0xE0
            bad.call if c < 0xC2
            return 2
          end
          c2 = s.getbyte(pos + 2) || 0
          bad.call if (c2 & 0xC0) != 0x80
          if c < 0xF0
            if c == 0xE0
              bad.call if c1 < 0xA0
            elsif c == 0xED
              bad.call if c1 >= 0xA0
            elsif c == 0xEF
              if c1 == 0xBF && c2 >= 0xBE
                fatal_err_msg(ErrCode::ERR_INVALID_CHAR, "invalid character in entity value\n")
              end
            end
            return 3
          end
          bad.call if ((s.getbyte(pos + 3) || 0) & 0xC0) != 0x80
          if c == 0xF0
            bad.call if c1 < 0x90
          elsif c >= 0xF4
            bad.call if c > 0xF4 || c1 >= 0x90
          end
          4
        end

        # xmlParseEntityValue: returns [value, orig]
        def parse_entity_value
          max_length = option?(PARSE_HUGE) ? XML_MAX_HUGE_LENGTH : XML_MAX_TEXT_LENGTH
          buf = SBuf.new(max_length)
          grow
          quote = cur_byte
          if quote != 0x22 && quote != 0x27
            fatal_err(ErrCode::ERR_ATTRIBUTE_NOT_STARTED)
            return [nil, nil]
          end
          @cur += 1
          start = @cur
          qch = quote == 0x22 ? "\"" : "'"
          while true
            return [nil, nil] if stopped?

            if @cur >= @end
              fatal_err_msg(ErrCode::ERR_ENTITY_NOT_FINISHED, nil)
              return [nil, nil]
            end
            # bulk: everything up to the quote or a NUL
            idx = @buf.byteindex(qch, @cur)
            nul = @buf.byteindex("\0", @cur)
            stop_at = [idx, nul].compact.min
            if stop_at.nil?
              advance_bytes(@end - @cur)
              next
            end
            advance_bytes(stop_at - @cur) if stop_at > @cur
            c = cur_byte
            if c == 0 && @cur < @end
              fatal_err_msg(ErrCode::ERR_INVALID_CHAR, "invalid character in entity value\n")
              return [nil, nil]
            end
            break if c == quote
          end
          length = @cur - start
          orig = @buf.byteslice(start, length)
          # remember replaced bytes within the value so the expansion reports them
          bad = @input.bad
          @entity_value_bad = bad&.filter_map { |b| b[0] - start if b[0] >= start && b[0] < @cur }
          expand_pes_in_entity_value(buf, orig, input_nr)
          @entity_value_bad = nil
          nextl(1)
          if buf.code != 0
            fatal_err(buf.code, "entity length too long")
            return [nil, orig]
          end
          [buf.str, orig]
        end

        # ---- entities in attribute values ----------------------------------------------------------

        # xmlCheckEntityInAttValue
        def check_entity_in_att_value(pent, depth)
          max_depth = option?(PARSE_HUGE) ? 40 : 20
          expanded_size = pent.length
          depth += 1
          if depth > max_depth
            fatal_err_msg(ErrCode::ERR_RESOURCE_LIMIT, "Maximum entity nesting depth exceeded")
            return
          end
          if (pent.flags & ENT_EXPANDING) != 0
            fatal_err(ErrCode::ERR_ENTITY_LOOP)
            halt
            return
          end
          flags = @in_subset == 0 ? (ENT_CHECKED | ENT_VALIDATED) : ENT_VALIDATED
          str = pent.content
          if str
            s = str.b
            pos = 0
            until stopped?
              c = s.getbyte(pos) || 0
              if c != 0x26
                break if c == 0

                if c == 0x3C
                  fatal_err_msg_str(ErrCode::ERR_LT_IN_ATTRIBUTE,
                    "'<' in entity '#{pent.name}' is not allowed in attributes values\n", pent.name)
                end
                pos += 1
              elsif s.getbyte(pos + 1) == 0x23
                val, pos = parse_string_char_ref(s, pos)
                if val == 0
                  pent.content = +""
                  break
                end
              else
                name, pos = parse_string_entity_ref(s, pos)
                if name.nil?
                  pent.content = +""
                  break
                end
                ent = lookup_general_entity(name, true)
                if ent && ent.etype != INTERNAL_PREDEFINED_ENTITY
                  if (ent.flags & flags) != flags
                    pent.flags |= ENT_EXPANDING
                    check_entity_in_att_value(ent, depth)
                    pent.flags &= ~ENT_EXPANDING
                  end
                  expanded_size = [expanded_size + ent.expanded_size + XML_ENT_FIXED_COST, ULONG_MAX].min
                end
              end
            end
          end
          pent.expanded_size = expanded_size if @in_subset == 0
          pent.flags |= flags
        end

        # xmlExpandEntityInAttValue; +st+ is a one-element array holding inSpace
        def expand_entity_in_att_value(buf, str, pent, normalize, st, depth, check)
          max_depth = option?(PARSE_HUGE) ? 40 : 20
          return if str.nil?

          depth += 1
          if depth > max_depth
            fatal_err_msg(ErrCode::ERR_RESOURCE_LIMIT, "Maximum entity nesting depth exceeded")
            return
          end
          if pent
            if (pent.flags & ENT_EXPANDING) != 0
              fatal_err(ErrCode::ERR_ENTITY_LOOP)
              halt
              return
            end
            return if check && parser_entity_check(pent.length) != 0
          end
          s = str.b
          pos = 0
          chunk_size = 0
          flush = lambda do
            if chunk_size > 0
              buf.add(s.byteslice(pos - chunk_size, chunk_size).force_encoding(Encoding::UTF_8))
              chunk_size = 0
            end
          end
          until stopped?
            c = s.getbyte(pos) || 0
            if c != 0x26
              break if c == 0

              if pent && c == 0x3C
                fatal_err_msg_str(ErrCode::ERR_LT_IN_ATTRIBUTE,
                  "'<' in entity '#{pent.name}' is not allowed in attributes values\n", pent.name)
                break
              end
              if c <= 0x20
                if normalize && st[0]
                  flush.call
                elsif c < 0x20
                  flush.call
                  buf.add(" ")
                else
                  chunk_size += 1
                end
                st[0] = true
              else
                chunk_size += 1
                st[0] = false
              end
              pos += 1
            elsif s.getbyte(pos + 1) == 0x23
              flush.call
              val, pos = parse_string_char_ref(s, pos)
              if val == 0
                pent.content = +"" if pent
                break
              end
              if val == 0x20
                buf.add(" ") if !normalize || !st[0]
                st[0] = true
              else
                buf.add_char(val)
                st[0] = false
              end
            else
              flush.call
              name, pos = parse_string_entity_ref(s, pos)
              if name.nil?
                pent.content = +"" if pent
                break
              end
              ent = lookup_general_entity(name, true)
              if ent && ent.etype == INTERNAL_PREDEFINED_ENTITY
                if ent.content.nil?
                  fatal_err_msg(ErrCode::ERR_INTERNAL_ERROR, "predefined entity has no content\n")
                  break
                end
                buf.add(ent.content)
                st[0] = false
              elsif ent && ent.content
                pent.flags |= ENT_EXPANDING if pent
                expand_entity_in_att_value(buf, ent.content, ent, normalize, st, depth, check)
                pent.flags &= ~ENT_EXPANDING if pent
              end
            end
          end
          flush.call
        end

        # xmlExpandEntitiesInAttValue
        def expand_entities_in_att_value(str, normalize)
          max_length = option?(PARSE_HUGE) ? XML_MAX_HUGE_LENGTH : XML_MAX_TEXT_LENGTH
          buf = SBuf.new(max_length)
          st = [true]
          expand_entity_in_att_value(buf, str, nil, normalize, st, input_nr, false)
          buf.chop! if normalize && st[0] && buf.size > 0
          if buf.code != 0
            fatal_err(buf.code, "AttValue length too long")
            return nil
          end
          buf.str
        end

        # xmlParseAttValueInternal: returns [value, alloc] (value nil on error)
        def parse_att_value_internal(normalize, is_namespace)
          max_length = option?(PARSE_HUGE) ? XML_MAX_HUGE_LENGTH : XML_MAX_TEXT_LENGTH
          replace_entities = @replace_entities != 0 || is_namespace
          buf = nil
          grow
          quote = cur_byte
          if quote != 0x22 && quote != 0x27
            fatal_err(ErrCode::ERR_ATTRIBUTE_NOT_STARTED)
            return [nil, false]
          end
          nextl(1)
          flags = @in_subset == 0 ? (ENT_CHECKED | ENT_VALIDATED) : ENT_VALIDATED
          in_space = true
          chunk_size = 0
          run_re = ATT_RUN[[quote, normalize ? true : false]]
          b = @buf
          ss = @ss
          while true
            return [nil, false] if stopped?

            if @cur >= @end
              fatal_err_msg(ErrCode::ERR_ATTRIBUTE_NOT_FINISHED, "AttValue: ' expected\n")
              return [nil, false]
            end
            grow if @end - @cur < 10
            c = b.getbyte(@cur)
            if c >= 0x80
              ss.pos = @cur
              n = ss.skip(MB_RUN_RE)
              if n
                chunk_size += n
                @col += b.byteslice(@cur, n).length
                @cur += n
              else
                l = utf8_multibyte_len("invalid character in attribute value\n")
                if l == 0
                  buf ||= SBuf.new(max_length)
                  if chunk_size > 0
                    buf.add(b.byteslice(@cur - chunk_size, chunk_size))
                    chunk_size = 0
                  end
                  buf.add("�")
                  @col += 1
                  @cur += 3
                else
                  chunk_size += l
                  nextl(l)
                end
              end
              in_space = false
            elsif c != 0x26
              if c > 0x20
                break if c == quote

                if c == 0x3C
                  fatal_err(ErrCode::ERR_LT_IN_ATTRIBUTE)
                  chunk_size += 1
                  nextl(1)
                else
                  ss.pos = @cur
                  n = ss.skip(run_re)
                  chunk_size += n
                  @col += n
                  @cur += n
                end
                in_space = false
                next
              elsif !Chars.byte_char?(c)
                fatal_err_msg(ErrCode::ERR_INVALID_CHAR, "invalid character in attribute value\n")
                buf ||= SBuf.new(max_length)
                if chunk_size > 0
                  buf.add(b.byteslice(@cur - chunk_size, chunk_size))
                  chunk_size = 0
                end
                buf.add("�")
                in_space = false
              else
                if normalize && in_space
                  if chunk_size > 0
                    buf ||= SBuf.new(max_length)
                    buf.add(b.byteslice(@cur - chunk_size, chunk_size))
                    chunk_size = 0
                  end
                elsif c < 0x20
                  buf ||= SBuf.new(max_length)
                  if chunk_size > 0
                    buf.add(b.byteslice(@cur - chunk_size, chunk_size))
                    chunk_size = 0
                  end
                  buf.add(" ")
                else
                  chunk_size += 1
                end
                in_space = true
                @cur += 1 if c == 0x0D && b.getbyte(@cur + 1) == 0x0A
              end
              nextl(1)
            elsif b.getbyte(@cur + 1) == 0x23
              buf ||= SBuf.new(max_length)
              if chunk_size > 0
                buf.add(b.byteslice(@cur - chunk_size, chunk_size))
                chunk_size = 0
              end
              val = parse_char_ref
              return [nil, false] if val == 0

              if val == 0x26 && !replace_entities
                buf.add("&#38;")
                in_space = false
              elsif val == 0x20
                buf.add(" ") if !normalize || !in_space
                in_space = true
              else
                buf.add_char(val)
                in_space = false
              end
            else
              if chunk_size > 0
                buf ||= SBuf.new(max_length)
                buf.add(b.byteslice(@cur - chunk_size, chunk_size))
                chunk_size = 0
              end
              name = parse_entity_ref_internal
              next if name.nil?

              ent = lookup_general_entity(name, true)
              next if ent.nil?

              buf ||= SBuf.new(max_length)
              if ent.etype == INTERNAL_PREDEFINED_ENTITY
                if ent.content.getbyte(0) == 0x26 && !replace_entities
                  buf.add("&#38;")
                else
                  buf.add(ent.content)
                end
                in_space = false
              elsif replace_entities
                st = [in_space]
                expand_entity_in_att_value(buf, ent.content, ent, normalize, st, input_nr, true)
                in_space = st[0]
              else
                check_entity_in_att_value(ent, input_nr) if (ent.flags & flags) != flags
                if parser_entity_check(ent.expanded_size) != 0
                  ent.content = +""
                  return [nil, false]
                end
                buf.add("&")
                buf.add(ent.name)
                buf.add(";")
                in_space = false
              end
            end
          end

          if buf.nil?
            len = chunk_size
            len -= 1 if normalize && in_space && chunk_size > 0
            ret = b.byteslice(@cur - chunk_size, len)
            alloc = false
          else
            buf.add(b.byteslice(@cur - chunk_size, chunk_size)) if chunk_size > 0
            buf.chop! if normalize && in_space && buf.size > 0
            if buf.code != 0
              fatal_err(buf.code, "AttValue length too long")
              ret = nil
            else
              ret = buf.str
            end
            alloc = true
          end
          nextl(1)
          [ret, alloc]
        end

        # xmlParseAttValue
        def parse_att_value
          parse_att_value_internal(false, false)[0]
        end
      end
    end
  end
end
