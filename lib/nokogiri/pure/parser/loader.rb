# frozen_string_literal: true

module Nokogiri
  module Pure
    module Parser
      # uri.c: RFC 3986 parsing (xmlParseURISafe, strict mode) and path resolution
      module URIParser
        ParsedURI = Struct.new(:scheme, :user, :server, :port, :path, :query, :fragment, :authority)

        module_function

        def alpha?(c) = c && ((c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A))
        def digit?(c) = c && c >= 0x30 && c <= 0x39
        def hexdig?(c) = c && (digit?(c) || (c >= 0x61 && c <= 0x66) || (c >= 0x41 && c <= 0x46))
        SUB_DELIMS = "!$&()*+,;='".bytes.freeze
        def sub_delim?(c) = c && SUB_DELIMS.include?(c)
        def unreserved?(c) = c && (alpha?(c) || digit?(c) || c == 0x2D || c == 0x2E || c == 0x5F || c == 0x7E)

        def pct_encoded?(s, i)
          s.getbyte(i) == 0x25 && hexdig?(s.getbyte(i + 1)) && hexdig?(s.getbyte(i + 2))
        end

        def pchar?(s, i)
          c = s.getbyte(i)
          unreserved?(c) || pct_encoded?(s, i) || sub_delim?(c) || c == 0x3A || c == 0x40
        end

        def nxt(s, i)
          s.getbyte(i) == 0x25 ? i + 3 : i + 1
        end

        # returns [ok, pos]
        def segment(s, i, forbid, empty)
          if !pchar?(s, i) || s.getbyte(i) == forbid
            return [empty, i]
          end

          i = nxt(s, i)
          i = nxt(s, i) while pchar?(s, i) && s.getbyte(i) != forbid
          [true, i]
        end

        def path_ab_empty(s, i)
          while s.getbyte(i) == 0x2F
            ok, i = segment(s, i + 1, nil, true)
            return [false, i] unless ok
          end
          [true, i]
        end

        def path_absolute(s, i)
          return [false, i] if s.getbyte(i) != 0x2F

          ok, i = segment(s, i + 1, nil, false)
          if ok
            while s.getbyte(i) == 0x2F
              ok2, i = segment(s, i + 1, nil, true)
              return [false, i] unless ok2
            end
          end
          [true, i]
        end

        def path_rootless(s, i, forbid = nil)
          ok, i = segment(s, i, forbid, false)
          return [false, i] unless ok

          while s.getbyte(i) == 0x2F
            ok, i = segment(s, i + 1, nil, true)
            return [false, i] unless ok
          end
          [true, i]
        end

        def dec_octet(s, i)
          c = s.getbyte(i)
          return nil unless digit?(c)

          c1 = s.getbyte(i + 1)
          c2 = s.getbyte(i + 2)
          if !digit?(c1)
            i + 1
          elsif c != 0x30 && digit?(c1) && !digit?(c2)
            i + 2
          elsif c == 0x31 && digit?(c1) && digit?(c2)
            i + 3
          elsif c == 0x32 && c1 >= 0x30 && c1 <= 0x34 && digit?(c2)
            i + 3
          elsif c == 0x32 && c1 == 0x35 && c2 && c2 >= 0x30 && c1 <= 0x35
            i + 3
          end
        end

        def host(s, i, uri)
          start = i
          if s.getbyte(i) == 0x5B
            i += 1
            i += 1 while (c = s.getbyte(i)) && c != 0x5D
            return [false, i] if s.getbyte(i) != 0x5D

            i += 1
          else
            done = false
            if digit?(s.getbyte(i))
              j = i
              ok = true
              4.times do |k|
                j = dec_octet(s, j)
                if j.nil?
                  ok = false
                  break
                end
                if k < 3
                  if s.getbyte(j) != 0x2E
                    ok = false
                    break
                  end
                  j += 1 if k == 0
                end
              end
              if ok
                i = j
                done = true
              end
            end
            unless done
              while (c = s.getbyte(i)) && (unreserved?(c) || pct_encoded?(s, i) || sub_delim?(c))
                i = nxt(s, i)
              end
            end
          end
          uri.server = i != start ? s.byteslice(start, i - start) : nil
          [true, i]
        end

        def authority(s, i, uri)
          j = i
          while (c = s.getbyte(j)) && (unreserved?(c) || pct_encoded?(s, j) || sub_delim?(c) || c == 0x3A)
            j = nxt(s, j)
          end
          if s.getbyte(j) == 0x40
            uri.user = s.byteslice(i, j - i)
            i = j + 1
          end
          ok, i = host(s, i, uri)
          return [false, i] unless ok

          if s.getbyte(i) == 0x3A
            i += 1
            return [false, i] unless digit?(s.getbyte(i))

            st = i
            i += 1 while digit?(s.getbyte(i))
            uri.port = s.byteslice(st, i - st).to_i
          end
          [true, i]
        end

        def query_or_fragment(s, i, frag)
          i = nxt(s, i) while pchar?(s, i) || [0x2F, 0x3F].include?(s.getbyte(i)) ||
            (frag && [0x5B, 0x5D].include?(s.getbyte(i)))
          i
        end

        def parse_uri_abs(s)
          uri = ParsedURI.new
          return nil unless alpha?(s.getbyte(0))

          i = 1
          i += 1 while (c = s.getbyte(i)) && (alpha?(c) || digit?(c) || c == 0x2B || c == 0x2D || c == 0x2E)
          return nil if s.getbyte(i) != 0x3A

          uri.scheme = s.byteslice(0, i)
          i += 1
          if s.getbyte(i) == 0x2F && s.getbyte(i + 1) == 0x2F
            ok, i = authority(s, i + 2, uri)
            return nil unless ok

            ok, i = path_ab_empty(s, i)
            return nil unless ok
          elsif s.getbyte(i) == 0x2F
            ok, i = path_absolute(s, i)
            return nil unless ok
          elsif pchar?(s, i)
            ok, i = path_rootless(s, i)
            return nil unless ok
          end
          finish(s, i, uri)
        end

        def finish(s, i, uri)
          if s.getbyte(i) == 0x3F
            j = query_or_fragment(s, i + 1, false)
            uri.query = s.byteslice(i + 1, j - i - 1)
            i = j
          end
          if s.getbyte(i) == 0x23
            j = query_or_fragment(s, i + 1, true)
            uri.fragment = s.byteslice(i + 1, j - i - 1)
            i = j
          end
          return nil if i != s.bytesize

          uri
        end

        def parse_relative(s)
          uri = ParsedURI.new
          i = 0
          if s.getbyte(0) == 0x2F && s.getbyte(1) == 0x2F
            ok, i = authority(s, 2, uri)
            return nil unless ok

            ok, i = path_ab_empty(s, i)
            return nil unless ok
          elsif s.getbyte(0) == 0x2F
            ok, i = path_absolute(s, 0)
            return nil unless ok
          elsif pchar?(s, 0)
            ok, i = path_rootless(s, 0, 0x3A)
            return nil unless ok
          end
          finish(s, i, uri)
        end

        # xmlParseURISafe (strict): returns a ParsedURI or nil if invalid
        def parse(str)
          return nil if str.nil?

          s = str.b
          parse_uri_abs(s) || parse_relative(s)
        end

        # xmlURIUnescapeString
        def unescape(str)
          str.b.gsub(/%([0-9A-Fa-f]{2})/) { $1.hex.chr }.force_encoding(Encoding::UTF_8)
        end

        # xmlNormalizePath (isFile = 1)
        def normalize_path(path)
          return path if path.nil?

          abs = path.start_with?("/")
          segs = []
          path.split("/", -1).each_with_index do |seg, idx|
            next if idx == 0 && abs && seg.empty?

            if seg == "."
              next
            elsif seg == ".." && !segs.empty? && segs[-1] != ".."
              segs.pop
            elsif seg.empty? && idx != path.count("/")
              next
            else
              segs << seg
            end
          end
          out = segs.join("/")
          abs ? "/#{out}" : out
        end

        # xmlResolvePath
        def resolve_path(esc_ref, base)
          if esc_ref.nil? || esc_ref.empty?
            return nil if base.nil? || base.empty?

            return base.dup
          end
          fragment = nil
          if (i = esc_ref.index("#"))
            fragment = esc_ref[i..]
            esc_ref = esc_ref[0, i]
          end
          ref = unescape(esc_ref)
          result = nil
          if base && !base.empty? && !ref.start_with?("/")
            i = base.length
            i -= 1 while i > 0 && base[i - 1] != "/"
            result = normalize_path(base[0, i] + ref) if i > 0
          end
          result ||= ref
          result += fragment if fragment
          result
        end

        # xmlBuildURISafe
        def build_uri(uri, base)
          return nil if uri.nil?
          return uri.dup if base.nil?

          unless uri.empty?
            ref = parse(uri)
            return nil if ref.nil?
            return uri.dup if ref.scheme
          end
          return resolve_path(uri, base) unless base.include?("://")

          Pure::URI_.build_uri(uri, base)
        end
      end

      # xmlLoadExternalEntity & the default entity loaders (parserInternals.c / xmlIO.c)
      module Loader
        module_function

        # xmlCanonicPath / xmlPathToURI
        def canonic_path(path)
          return nil if path.nil?

          if path.include?("://")
            path.b.gsub(%r{[^A-Za-z0-9\-_.!~*'()@:/?#\[\]$&+,;=%]}n) { |c| format("%%%02X", c.ord) }
              .force_encoding(Encoding::UTF_8)
          else
            path.dup
          end
        end

        def path_to_uri(path)
          canonic_path(path)
        end

        # xmlConvertUriToPath
        def uri_to_path(uri)
          if uri.downcase.start_with?("file://localhost/")
            URIParser.unescape(uri[16..])
          elsif uri.downcase.start_with?("file:///")
            URIParser.unescape(uri[7..])
          elsif uri.downcase.start_with?("file:/")
            URIParser.unescape(uri[5..])
          else
            uri
          end
        end

        # read a resource: returns [code, bytes]
        def open_resource(filename)
          path = uri_to_path(filename)
          begin
            return [ErrCode::IO_EISDIR, nil] if File.directory?(path)

            [0, File.binread(path)]
          rescue Errno::ENOENT, Errno::EINVAL, Errno::ENOTDIR, Errno::ENAMETOOLONG
            [ErrCode::IO_ENOENT, nil]
          rescue Errno::EACCES
            [ErrCode::IO_EACCES, nil]
          rescue SystemCallError, IOError
            [ErrCode::IO_UNKNOWN, nil]
          end
        end

        # xmlNewInputFromFile
        def new_input_from_file(ctxt, filename)
          if filename.downcase.start_with?("http://")
            # libxml2's nanohttp client: without network access the fetch fails and
            # xmlCheckHTTPInput reports a load error for the (not yet named) input
            ctxt&.err_io(ErrCode::IO_LOAD_ERROR, "<null>")
            return nil
          end
          code, bytes = open_resource(filename)
          if bytes.nil?
            ctxt&.err_io(code, filename)
            return nil
          end
          input = ctxt ? ctxt.new_input_stream : Input.new
          input.set_raw(bytes)
          input.filename = canonic_path(filename)
          input
        end

        def network?(url)
          url.downcase.start_with?("ftp://", "http://")
        end

        # xmlLoadExternalEntity
        def load_external_entity(url, _id, ctxt)
          return nil if url.nil?

          canonic = canonic_path(url)
          if ctxt && ctxt.option?(PARSE_NONET) && network?(canonic)
            ctxt.err_io(ErrCode::IO_NETWORK_ATTEMPT, canonic)
            # also forwarded to the global error handler (__xmlIOErr)
            Errors.report(XmlError.new(domain: Domain::IO, code: ErrCode::IO_NETWORK_ATTEMPT,
              message: "Attempt to load network entity: #{canonic}\n", level: Level::ERROR,
              str1: canonic))
            return nil
          end
          new_input_from_file(ctxt, canonic)
        end
      end
    end
  end
end
