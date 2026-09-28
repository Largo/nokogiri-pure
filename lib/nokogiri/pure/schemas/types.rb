# frozen_string_literal: true

require_relative "structs"
require_relative "common"
require_relative "types_names"
require_relative "types_compare"

# Port of libxml2 2.13.9 xmlschemastypes.c: the built-in XML Schema datatypes (type bank,
# lexical validation, value representation). Comparison, facet checking and canonical values
# live in types_compare.rb, name / URI / language helpers in types_names.rb.
#
# Strings are processed byte-wise like the C code (C's NUL terminator is emulated by
# `getbyte(i) || 0`); values are UTF-8 Ruby Strings.
module Nokogiri
  module Pure
    module Schemas
      module Types
        extend self

        XML_SCHEMAS_NAMESPACE_NAME = "http://www.w3.org/2001/XMLSchema"
        LONG_MAX = (1 << 63) - 1
        LONG_MIN = -(1 << 63)
        ULONG_MAX = (1 << 64) - 1

        SECS_PER_MIN = 60
        MINS_PER_HOUR = 60
        HOURS_PER_DAY = 24
        SECS_PER_HOUR = MINS_PER_HOUR * SECS_PER_MIN
        SECS_PER_DAY = HOURS_PER_DAY * SECS_PER_HOUR
        MINS_PER_DAY = HOURS_PER_DAY * MINS_PER_HOUR

        DAYS_IN_MONTH = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31].freeze
        DAYS_IN_MONTH_LEAP = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31].freeze
        DAY_IN_YEAR_BY_MONTH = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334].freeze
        DAY_IN_LEAP_YEAR_BY_MONTH = [0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335].freeze

        # struct _xmlSchemaVal. The C value union is flattened:
        # - str: string types, QName/NOTATION local name (qname.name), hexBinary/base64Binary
        #   string (hex.str / base64.str) and the decimal string (decimal.str) — like the C union,
        #   these all alias the first union member
        # - uri: QName/NOTATION namespace (qname.uri)
        # - integral_places / fractional_places: decimal
        # - total: hexBinary / base64Binary octet count
        # - year, mon, day, hour, min, sec, tz_flag, tzo: date/time (C bitfields; see date_add)
        # - mon, day, sec: duration (dur.mon / dur.day / dur.sec)
        # - f (float, stored as a single-precision-rounded Float), d (double), b (boolean int)
        class SchemaVal
          attr_accessor :type, :next, :str, :uri, :integral_places, :fractional_places, :total,
            :year, :mon, :day, :hour, :min, :sec, :tz_flag, :tzo, :f, :d, :b

          def initialize(type)
            @type = type
            @next = nil
            @str = nil
            @uri = nil
            @integral_places = 0
            @fractional_places = 0
            @total = 0
            @year = 0
            @mon = 0
            @day = 0
            @hour = 0
            @min = 0
            @sec = 0.0
            @tz_flag = 0
            @tzo = 0
            @f = 0.0
            @d = 0.0
            @b = 0
          end

          def inspect
            v = case @type
            when XML_SCHEMAS_DECIMAL, XML_SCHEMAS_INTEGER..XML_SCHEMAS_UBYTE
              "dec=#{@str}"
            when XML_SCHEMAS_TIME..XML_SCHEMAS_DATETIME
              "date=#{@year}-#{@mon}-#{@day}T#{@hour}:#{@min}:#{@sec} tz=#{@tz_flag}/#{@tzo}"
            when XML_SCHEMAS_DURATION then "dur=#{@mon}m #{@day}d #{@sec}s"
            when XML_SCHEMAS_FLOAT then "f=#{@f}"
            when XML_SCHEMAS_DOUBLE then "d=#{@d}"
            when XML_SCHEMAS_BOOLEAN then "b=#{@b}"
            when XML_SCHEMAS_QNAME, XML_SCHEMAS_NOTATION then "{#{@uri}}#{@str}"
            when XML_SCHEMAS_HEXBINARY, XML_SCHEMAS_BASE64BINARY then "#{@str.inspect} total=#{@total}"
            else @str.inspect
            end
            "#<Types::SchemaVal type=#{@type} #{v}#{@next ? " next=#{@next.inspect}" : ""}>"
          end
        end

        @initialized = false
        @bank = nil
        @builtin = {}

        # IS_BLANK_CH
        def blank_ch?(c) = c == 0x20 || c == 0x9 || c == 0xA || c == 0xD

        # xmlSchemaTypeErrMemory: memory errors cannot happen in Ruby
        def type_err_memory = nil

        # xmlSchemaNewValue
        def new_value(type) = SchemaVal.new(type)

        # xmlSchemaNewMinLengthFacet
        def new_min_length_facet(value)
          ret = SchemaFacet.new
          ret.type = XML_SCHEMA_FACET_MINLENGTH
          ret.val = new_value(XML_SCHEMAS_NNINTEGER)
          s = format("%+d.0", value)
          ret.val.str = s
          ret.val.integral_places = s.bytesize - 3
          ret.val.fractional_places = 1
          ret
        end

        # xmlSchemaInitBasicType
        def init_basic_type(name, type, base_type)
          ret = SchemaType.new
          ret.name = name
          ret.target_namespace = XML_SCHEMAS_NAMESPACE_NAME
          ret.type = XML_SCHEMA_TYPE_BASIC
          ret.base_type = base_type
          ret.content_type = XML_SCHEMA_CONTENT_BASIC
          # Primitive types.
          case type
          when XML_SCHEMAS_STRING, XML_SCHEMAS_DECIMAL, XML_SCHEMAS_DATE, XML_SCHEMAS_DATETIME,
            XML_SCHEMAS_TIME, XML_SCHEMAS_GYEAR, XML_SCHEMAS_GYEARMONTH, XML_SCHEMAS_GMONTH,
            XML_SCHEMAS_GMONTHDAY, XML_SCHEMAS_GDAY, XML_SCHEMAS_DURATION, XML_SCHEMAS_FLOAT,
            XML_SCHEMAS_DOUBLE, XML_SCHEMAS_BOOLEAN, XML_SCHEMAS_ANYURI, XML_SCHEMAS_HEXBINARY,
            XML_SCHEMAS_BASE64BINARY, XML_SCHEMAS_QNAME, XML_SCHEMAS_NOTATION
            ret.flags |= XML_SCHEMAS_TYPE_BUILTIN_PRIMITIVE
          end
          # Set variety.
          case type
          when XML_SCHEMAS_ANYTYPE, XML_SCHEMAS_ANYSIMPLETYPE
            nil
          when XML_SCHEMAS_IDREFS, XML_SCHEMAS_NMTOKENS, XML_SCHEMAS_ENTITIES
            ret.flags |= XML_SCHEMAS_TYPE_VARIETY_LIST
            ret.facets = new_min_length_facet(1)
            ret.flags |= XML_SCHEMAS_TYPE_HAS_FACETS
          else
            ret.flags |= XML_SCHEMAS_TYPE_VARIETY_ATOMIC
          end
          @bank[[name, XML_SCHEMAS_NAMESPACE_NAME]] ||= ret
          ret.built_in_type = type
          @builtin[type] = ret
          ret
        end

        # xmlSchemaValDecimalGetFractionalPart: returns the byte index of the fractional part
        def val_decimal_get_fractional_part(decimal)
          2 + decimal.integral_places
        end

        # xmlSchemaValDecimalIsInteger
        def val_decimal_is_integer(decimal)
          decimal.fractional_places == 1 &&
            decimal.str.getbyte(val_decimal_get_fractional_part(decimal)) == 0x30
        end

        # xmlSchemaValDecimalGetSignificantDigitCount
        def val_decimal_get_significant_digit_count(decimal)
          fractional_places = val_decimal_is_integer(decimal) ? 0 : decimal.fractional_places
          integral_places = decimal.integral_places
          integral_places = 0 if integral_places == 1 && decimal.str.getbyte(1) == 0x30
          # 0, but that's still 1 significant digit
          return 1 if integral_places + fractional_places == 0

          integral_places + fractional_places
        end

        # xmlSchemaValDecimalCompare (decimals are SchemaVal or anything with str/integral_places)
        def val_decimal_compare(lhs, rhs)
          ls = lhs.str
          rs = rhs.str
          # may be +0 and -0 for some reason, handle
          return 0 if ls.byteslice(1..) == "0.0" && rs.byteslice(1..) == "0.0"

          # first take care of sign
          return rs.getbyte(0) - ls.getbyte(0) if ls.getbyte(0) != rs.getbyte(0)

          sign = ls.getbyte(0) == 0x2D ? -1 : 1
          if lhs.integral_places != rhs.integral_places
            return (lhs.integral_places - rhs.integral_places) * sign
          end

          (ls.byteslice(1..) <=> rs.byteslice(1..)) * sign
        end

        TmpDecimal = Struct.new(:str, :integral_places, :fractional_places)

        # xmlSchemaValDecimalCompareWithInteger
        def val_decimal_compare_with_integer(lhs, rhs)
          buf = format("%+d.0", rhs)
          val_decimal_compare(lhs, TmpDecimal.new(buf, buf.bytesize - 3, 1))
        end

        # xmlSchemaAddParticle (the local variant of xmlschemastypes.c)
        def add_particle
          SchemaParticle.new(type: XML_SCHEMA_TYPE_PARTICLE, min_occurs: 1, max_occurs: 1)
        end

        # xmlSchemaFreeTypeEntry
        def free_type_entry(_type, _name) = nil

        # xmlSchemaCleanupTypesInternal
        def cleanup_types_internal
          @bank = nil
          @builtin = {}
        end

        # xmlSchemaInitTypes
        def init_types
          return 0 if @initialized

          @bank = {}
          @builtin = {}
          # 3.4.7 Built-in Complex Type Definition
          any_type = init_basic_type("anyType", XML_SCHEMAS_ANYTYPE, nil)
          any_type.base_type = any_type
          any_type.content_type = XML_SCHEMA_CONTENT_MIXED
          # Init the content type.
          any_type.content_type = XML_SCHEMA_CONTENT_MIXED
          # First particle.
          particle = add_particle
          any_type.subtypes = particle
          # Sequence model group.
          sequence = SchemaModelGroup.new(type: XML_SCHEMA_TYPE_SEQUENCE)
          particle.children = sequence
          # Second particle.
          particle = add_particle
          particle.min_occurs = 0
          particle.max_occurs = UNBOUNDED
          sequence.children = particle
          # The wildcard
          wild = SchemaWildcard.new(type: XML_SCHEMA_TYPE_ANY, any: 1,
            process_contents: XML_SCHEMAS_ANY_LAX)
          particle.children = wild
          # Create the attribute wildcard (memset 0: its type stays 0).
          wild = SchemaWildcard.new(type: 0, any: 1, process_contents: XML_SCHEMAS_ANY_LAX)
          any_type.attribute_wildcard = wild

          any_simple = init_basic_type("anySimpleType", XML_SCHEMAS_ANYSIMPLETYPE, any_type)
          # primitive datatypes
          string = init_basic_type("string", XML_SCHEMAS_STRING, any_simple)
          decimal = init_basic_type("decimal", XML_SCHEMAS_DECIMAL, any_simple)
          init_basic_type("date", XML_SCHEMAS_DATE, any_simple)
          init_basic_type("dateTime", XML_SCHEMAS_DATETIME, any_simple)
          init_basic_type("time", XML_SCHEMAS_TIME, any_simple)
          init_basic_type("gYear", XML_SCHEMAS_GYEAR, any_simple)
          init_basic_type("gYearMonth", XML_SCHEMAS_GYEARMONTH, any_simple)
          init_basic_type("gMonth", XML_SCHEMAS_GMONTH, any_simple)
          init_basic_type("gMonthDay", XML_SCHEMAS_GMONTHDAY, any_simple)
          init_basic_type("gDay", XML_SCHEMAS_GDAY, any_simple)
          init_basic_type("duration", XML_SCHEMAS_DURATION, any_simple)
          @float_def = init_basic_type("float", XML_SCHEMAS_FLOAT, any_simple)
          init_basic_type("double", XML_SCHEMAS_DOUBLE, any_simple)
          init_basic_type("boolean", XML_SCHEMAS_BOOLEAN, any_simple)
          init_basic_type("anyURI", XML_SCHEMAS_ANYURI, any_simple)
          init_basic_type("hexBinary", XML_SCHEMAS_HEXBINARY, any_simple)
          init_basic_type("base64Binary", XML_SCHEMAS_BASE64BINARY, any_simple)
          init_basic_type("NOTATION", XML_SCHEMAS_NOTATION, any_simple)
          init_basic_type("QName", XML_SCHEMAS_QNAME, any_simple)

          # derived datatypes
          integer = init_basic_type("integer", XML_SCHEMAS_INTEGER, decimal)
          non_positive = init_basic_type("nonPositiveInteger", XML_SCHEMAS_NPINTEGER, integer)
          init_basic_type("negativeInteger", XML_SCHEMAS_NINTEGER, non_positive)
          long = init_basic_type("long", XML_SCHEMAS_LONG, integer)
          int = init_basic_type("int", XML_SCHEMAS_INT, long)
          short = init_basic_type("short", XML_SCHEMAS_SHORT, int)
          init_basic_type("byte", XML_SCHEMAS_BYTE, short)
          non_negative = init_basic_type("nonNegativeInteger", XML_SCHEMAS_NNINTEGER, integer)
          ulong = init_basic_type("unsignedLong", XML_SCHEMAS_ULONG, non_negative)
          uint = init_basic_type("unsignedInt", XML_SCHEMAS_UINT, ulong)
          ushort = init_basic_type("unsignedShort", XML_SCHEMAS_USHORT, uint)
          init_basic_type("unsignedByte", XML_SCHEMAS_UBYTE, ushort)
          init_basic_type("positiveInteger", XML_SCHEMAS_PINTEGER, non_negative)
          norm_string = init_basic_type("normalizedString", XML_SCHEMAS_NORMSTRING, string)
          token = init_basic_type("token", XML_SCHEMAS_TOKEN, norm_string)
          init_basic_type("language", XML_SCHEMAS_LANGUAGE, token)
          name = init_basic_type("Name", XML_SCHEMAS_NAME, token)
          nmtoken = init_basic_type("NMTOKEN", XML_SCHEMAS_NMTOKEN, token)
          ncname = init_basic_type("NCName", XML_SCHEMAS_NCNAME, name)
          init_basic_type("ID", XML_SCHEMAS_ID, ncname)
          idref = init_basic_type("IDREF", XML_SCHEMAS_IDREF, ncname)
          entity = init_basic_type("ENTITY", XML_SCHEMAS_ENTITY, ncname)
          # Derived list types.
          init_basic_type("ENTITIES", XML_SCHEMAS_ENTITIES, any_simple).subtypes = entity
          init_basic_type("IDREFS", XML_SCHEMAS_IDREFS, any_simple).subtypes = idref
          init_basic_type("NMTOKENS", XML_SCHEMAS_NMTOKENS, any_simple).subtypes = nmtoken

          @initialized = true
          0
        end

        # xmlSchemaCleanupTypes
        def cleanup_types
          return unless @initialized

          cleanup_types_internal
          @initialized = false
        end

        # xmlSchemaIsBuiltInTypeFacet
        def is_built_in_type_facet(type, facet_type)
          return -1 if type.nil?
          return -1 if type.type != XML_SCHEMA_TYPE_BASIC

          case type.built_in_type
          when XML_SCHEMAS_BOOLEAN
            (facet_type == XML_SCHEMA_FACET_PATTERN || facet_type == XML_SCHEMA_FACET_WHITESPACE) ? 1 : 0
          when XML_SCHEMAS_STRING, XML_SCHEMAS_NOTATION, XML_SCHEMAS_QNAME, XML_SCHEMAS_ANYURI,
            XML_SCHEMAS_BASE64BINARY, XML_SCHEMAS_HEXBINARY
            case facet_type
            when XML_SCHEMA_FACET_LENGTH, XML_SCHEMA_FACET_MINLENGTH, XML_SCHEMA_FACET_MAXLENGTH,
              XML_SCHEMA_FACET_PATTERN, XML_SCHEMA_FACET_ENUMERATION, XML_SCHEMA_FACET_WHITESPACE
              1
            else
              0
            end
          when XML_SCHEMAS_DECIMAL
            case facet_type
            when XML_SCHEMA_FACET_TOTALDIGITS, XML_SCHEMA_FACET_FRACTIONDIGITS,
              XML_SCHEMA_FACET_PATTERN, XML_SCHEMA_FACET_WHITESPACE, XML_SCHEMA_FACET_ENUMERATION,
              XML_SCHEMA_FACET_MAXINCLUSIVE, XML_SCHEMA_FACET_MAXEXCLUSIVE,
              XML_SCHEMA_FACET_MININCLUSIVE, XML_SCHEMA_FACET_MINEXCLUSIVE
              1
            else
              0
            end
          when XML_SCHEMAS_TIME, XML_SCHEMAS_GDAY, XML_SCHEMAS_GMONTH, XML_SCHEMAS_GMONTHDAY,
            XML_SCHEMAS_GYEAR, XML_SCHEMAS_GYEARMONTH, XML_SCHEMAS_DATE, XML_SCHEMAS_DATETIME,
            XML_SCHEMAS_DURATION, XML_SCHEMAS_FLOAT, XML_SCHEMAS_DOUBLE
            case facet_type
            when XML_SCHEMA_FACET_PATTERN, XML_SCHEMA_FACET_ENUMERATION, XML_SCHEMA_FACET_WHITESPACE,
              XML_SCHEMA_FACET_MAXINCLUSIVE, XML_SCHEMA_FACET_MAXEXCLUSIVE,
              XML_SCHEMA_FACET_MININCLUSIVE, XML_SCHEMA_FACET_MINEXCLUSIVE
              1
            else
              0
            end
          else
            0
          end
        end

        # xmlSchemaGetBuiltInType
        def get_built_in_type(type)
          init_types unless @initialized
          return nil if type == XML_SCHEMAS_UNKNOWN

          @builtin[type]
        end

        # xmlSchemaValueAppend
        def value_append(prev, cur)
          return -1 if prev.nil? || cur.nil?

          prev.next = cur
          0
        end

        # xmlSchemaValueGetNext
        def value_get_next(cur)
          cur&.next
        end

        # xmlSchemaValueGetAsString
        def value_get_as_string(val)
          return nil if val.nil?

          case val.type
          when XML_SCHEMAS_STRING, XML_SCHEMAS_NORMSTRING, XML_SCHEMAS_ANYSIMPLETYPE,
            XML_SCHEMAS_TOKEN, XML_SCHEMAS_LANGUAGE, XML_SCHEMAS_NMTOKEN, XML_SCHEMAS_NAME,
            XML_SCHEMAS_NCNAME, XML_SCHEMAS_ID, XML_SCHEMAS_IDREF, XML_SCHEMAS_ENTITY,
            XML_SCHEMAS_ANYURI
            val.str
          end
        end

        # xmlSchemaValueGetAsBoolean
        def value_get_as_boolean(val)
          return 0 if val.nil? || val.type != XML_SCHEMAS_BOOLEAN

          val.b
        end

        # xmlSchemaNewStringValue
        def new_string_value(type, value)
          return nil if type != XML_SCHEMAS_STRING

          val = SchemaVal.new(type)
          val.str = value
          val
        end

        # xmlSchemaNewNOTATIONValue
        def new_notation_value(name, ns)
          val = new_value(XML_SCHEMAS_NOTATION)
          val.str = name
          val.uri = ns unless ns.nil?
          val
        end

        # xmlSchemaNewQNameValue
        def new_q_name_value(namespace_name, local_name)
          val = new_value(XML_SCHEMAS_QNAME)
          val.str = local_name
          val.uri = namespace_name
          val
        end

        # xmlSchemaFreeValue: values are garbage collected
        def free_value(_value) = nil

        # xmlSchemaGetPredefinedType
        def get_predefined_type(name, ns)
          init_types unless @initialized
          return nil if name.nil?

          @bank[[name, ns]]
        end

        # xmlSchemaGetBuiltInListSimpleTypeItemType
        def get_built_in_list_simple_type_item_type(type)
          return nil if type.nil? || type.type != XML_SCHEMA_TYPE_BASIC

          case type.built_in_type
          when XML_SCHEMAS_NMTOKENS then @builtin[XML_SCHEMAS_NMTOKEN]
          when XML_SCHEMAS_IDREFS then @builtin[XML_SCHEMAS_IDREF]
          when XML_SCHEMAS_ENTITIES then @builtin[XML_SCHEMAS_ENTITY]
          end
        end

        # ---- Dates / times ------------------------------------------------------------------

        # IS_LEAP
        def is_leap(y) = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0

        # MAX_DAYINMONTH
        def max_dayinmonth(yr, mon)
          is_leap(yr) ? DAYS_IN_MONTH_LEAP[mon - 1] : DAYS_IN_MONTH[mon - 1]
        end

        # VALID_MDAY
        def valid_mday(dt)
          # (dt->mon - 1) is used as an index; mon is always >= 1 when this is reached
          m = dt.mon - 1
          if is_leap(dt.year)
            dt.day <= DAYS_IN_MONTH_LEAP[m]
          else
            dt.day <= DAYS_IN_MONTH[m]
          end
        end

        # VALID_DATE
        def valid_date(dt)
          dt.year != 0 && dt.mon >= 1 && dt.mon <= 12 && valid_mday(dt)
        end

        # VALID_TIME
        def valid_time(dt)
          (((dt.hour >= 0 && dt.hour <= 23) && (dt.min >= 0 && dt.min <= 59) &&
            (dt.sec >= 0 && dt.sec < 60)) ||
            (dt.hour == 24 && dt.min == 0 && dt.sec == 0)) &&
            (dt.tzo >= -840 && dt.tzo <= 840)
        end

        # _xmlSchemaParseGYear. Returns [ret, new_cur].
        def parse_g_year(dt, s, cur)
          c = s.getbyte(cur) || 0
          return [-1, cur] if (c < 0x30 || c > 0x39) && c != 0x2D && c != 0x2B

          isneg = false
          if c == 0x2D
            isneg = true
            cur += 1
          end
          first_char = cur
          digcnt = 0
          while (c = s.getbyte(cur) || 0) >= 0x30 && c <= 0x39
            digit = c - 0x30
            return [2, cur] if dt.year > LONG_MAX / 10

            dt.year *= 10
            return [2, cur] if dt.year > LONG_MAX - digit

            dt.year += digit
            cur += 1
            digcnt += 1
          end
          # year must be at least 4 digits (CCYY); over 4 digits cannot have a leading zero.
          return [1, cur] if digcnt < 4 || (digcnt > 4 && s.getbyte(first_char) == 0x30)

          dt.year = -dt.year if isneg
          return [2, cur] if dt.year == 0

          [0, cur]
        end

        # PARSE_2_DIGITS: returns [invalid, num] (num nil when invalid)
        def parse_2_digits(s, cur)
          c0 = s.getbyte(cur) || 0
          c1 = s.getbyte(cur + 1) || 0
          return [1, nil] if c0 < 0x30 || c0 > 0x39 || c1 < 0x30 || c1 > 0x39

          [0, (c0 - 0x30) * 10 + (c1 - 0x30)]
        end

        # _xmlSchemaParseGMonth. Returns [ret, new_cur].
        def parse_g_month(dt, s, cur)
          invalid, value = parse_2_digits(s, cur)
          return [invalid, cur] if invalid != 0

          cur += 2
          return [2, cur] if value < 1 || value > 12

          dt.mon = value
          [0, cur]
        end

        # _xmlSchemaParseGDay. Returns [ret, new_cur].
        def parse_g_day(dt, s, cur)
          invalid, value = parse_2_digits(s, cur)
          return [invalid, cur] if invalid != 0

          cur += 2
          return [2, cur] if value < 1 || value > 31

          dt.day = value
          [0, cur]
        end

        # _xmlSchemaParseTime. Returns [ret, new_cur].
        def parse_time(dt, s, start)
          cur = start
          invalid, value = parse_2_digits(s, cur)
          return [invalid, start] if invalid != 0

          cur += 2
          return [1, start] if (s.getbyte(cur) || 0) != 0x3A
          return [2, start] if !(value >= 0 && value <= 23) && value != 24 # Allow end-of-day hour

          cur += 1
          # the ':' insures this string is xs:time
          dt.hour = value

          invalid, value = parse_2_digits(s, cur)
          return [invalid, start] if invalid != 0

          cur += 2
          return [2, start] if value < 0 || value > 59

          dt.min = value
          return [1, start] if (s.getbyte(cur) || 0) != 0x3A

          cur += 1
          # PARSE_FLOAT(dt->sec, cur, ret)
          invalid, value = parse_2_digits(s, cur)
          cur += 2
          return [invalid, start] if invalid != 0

          dt.sec = value.to_f
          if (s.getbyte(cur) || 0) == 0x2E
            mult = 1.0
            cur += 1
            c = s.getbyte(cur) || 0
            invalid = 1 if c < 0x30 || c > 0x39
            while (c = s.getbyte(cur) || 0) >= 0x30 && c <= 0x39
              mult /= 10
              dt.sec += (c - 0x30) * mult
              cur += 1
            end
          end
          return [invalid, start] if invalid != 0
          return [2, start] unless valid_time(dt)

          [0, cur]
        end

        # _xmlSchemaParseTimeZone. Returns [ret, new_cur].
        def parse_time_zone(dt, s, start)
          cur = start
          case s.getbyte(cur) || 0
          when 0
            dt.tz_flag = 0
            dt.tzo = 0
          when 0x5A # 'Z'
            dt.tz_flag = 1
            dt.tzo = 0
            cur += 1
          when 0x2B, 0x2D
            isneg = s.getbyte(cur) == 0x2D
            cur += 1
            invalid, tmp = parse_2_digits(s, cur)
            return [invalid, start] if invalid != 0

            cur += 2
            return [2, start] if tmp < 0 || tmp > 23
            return [1, start] if (s.getbyte(cur) || 0) != 0x3A

            cur += 1
            dt.tzo = tmp * 60
            invalid, tmp = parse_2_digits(s, cur)
            return [invalid, start] if invalid != 0

            cur += 2
            return [2, start] if tmp < 0 || tmp > 59

            dt.tzo += tmp
            dt.tzo = -dt.tzo if isneg
            return [2, start] unless dt.tzo >= -840 && dt.tzo <= 840

            dt.tz_flag = 1
          else
            return [1, start]
          end
          [0, cur]
        end

        # _xmlSchemaBase64Decode
        def base64_decode(ch)
          return ch - 0x41 if ch >= 0x41 && ch <= 0x5A
          return ch - 0x61 + 26 if ch >= 0x61 && ch <= 0x7A
          return ch - 0x30 + 52 if ch >= 0x30 && ch <= 0x39
          return 62 if ch == 0x2B
          return 63 if ch == 0x2F
          return 64 if ch == 0x3D

          -1
        end

        # IS_TZO_CHAR
        def tzo_char?(c) = c == 0 || c == 0x5A || c == 0x2B || c == 0x2D

        # xmlSchemaValidateDates. Returns [ret, val].
        def validate_dates(type, date_time, want_val, collapse)
          return [-1, nil] if date_time.nil?

          s = date_time
          cur = 0
          if collapse
            cur += 1 while blank_ch?(s.getbyte(cur) || 0)
          end
          dt = new_value(XML_SCHEMAS_UNKNOWN)
          failed = true
          catch(:date_error) do
            catch(:done) do
              if s.getbyte(cur) == 0x2D && s.getbyte(cur + 1) == 0x2D
                # It's an incomplete date (xs:gMonthDay, xs:gMonth or xs:gDay)
                cur += 2
                # is it an xs:gDay?
                if s.getbyte(cur) == 0x2D
                  return [1, nil] if type == XML_SCHEMAS_GMONTH

                  cur += 1
                  ret, cur = parse_g_day(dt, s, cur)
                  return [1, nil] if ret != 0

                  cur = return_type_if_valid(dt, s, cur, XML_SCHEMAS_GDAY)
                  return [1, nil]
                end
                # it should be an xs:gMonthDay or xs:gMonth
                ret, cur = parse_g_month(dt, s, cur)
                return [1, nil] if ret != 0

                # a '-' char could indicate this type is xs:gMonthDay or a negative time zone
                # offset. Check for xs:gMonthDay first.
                if s.getbyte(cur) == 0x2D
                  rewnd = cur
                  cur += 1
                  ret, cur = parse_g_day(dt, s, cur)
                  if ret == 0 && (s.getbyte(cur) || 0) != 0x3A
                    if valid_mday(dt)
                      cur = return_type_if_valid(dt, s, cur, XML_SCHEMAS_GMONTHDAY)
                      return [1, nil]
                    end
                  end
                  # not xs:gMonthDay so rewind and check if just xs:gMonth with an optional time zone.
                  cur = rewnd
                end
                cur = return_type_if_valid(dt, s, cur, XML_SCHEMAS_GMONTH)
                return [1, nil]
              end

              # It's a right-truncated date or an xs:time.
              # Try to parse an xs:time then fallback on right-truncated dates.
              c = s.getbyte(cur) || 0
              if c >= 0x30 && c <= 0x39
                ret, cur = parse_time(dt, s, cur)
                # it's an xs:time
                cur = return_type_if_valid(dt, s, cur, XML_SCHEMAS_TIME) if ret == 0
              end

              # fallback on date parsing
              cur = 0
              ret, cur = parse_g_year(dt, s, cur)
              return [1, nil] if ret != 0

              # is it an xs:gYear?
              cur = return_type_if_valid(dt, s, cur, XML_SCHEMAS_GYEAR)
              return [1, nil] if s.getbyte(cur) != 0x2D

              cur += 1
              ret, cur = parse_g_month(dt, s, cur)
              return [1, nil] if ret != 0

              # is it an xs:gYearMonth?
              cur = return_type_if_valid(dt, s, cur, XML_SCHEMAS_GYEARMONTH)
              return [1, nil] if s.getbyte(cur) != 0x2D

              cur += 1
              ret, cur = parse_g_day(dt, s, cur)
              return [1, nil] if ret != 0 || !valid_date(dt)

              # is it an xs:date?
              cur = return_type_if_valid(dt, s, cur, XML_SCHEMAS_DATE)
              return [1, nil] if s.getbyte(cur) != 0x54 # 'T'

              cur += 1
              # it should be an xs:dateTime
              ret, cur = parse_time(dt, s, cur)
              return [1, nil] if ret != 0

              ret, cur = parse_time_zone(dt, s, cur)
              if collapse
                cur += 1 while blank_ch?(s.getbyte(cur) || 0)
              end
              return [1, nil] if ret != 0 || (s.getbyte(cur) || 0) != 0 || !(valid_date(dt) && valid_time(dt))

              dt.type = XML_SCHEMAS_DATETIME
            end
            failed = false
          end
          return [1, nil] if failed

          # done:
          return [1, nil] if type != XML_SCHEMAS_UNKNOWN && type != dt.type

          [0, want_val ? dt : nil]
        end

        # RETURN_TYPE_IF_VALID(t): throws :done on success ("goto done"), :date_error for
        # "goto error"; otherwise returns the unchanged cursor.
        def return_type_if_valid(dt, s, cur, t)
          if tzo_char?(s.getbyte(cur) || 0)
            ret, ncur = parse_time_zone(dt, s, cur)
            if ret == 0
              throw :date_error if (s.getbyte(ncur) || 0) != 0

              dt.type = t
              throw :done
            end
          end
          cur
        end
        private :return_type_if_valid

        # xmlSchemaValidateDuration. Returns [ret, val].
        DURATION_DESIG = [0x59, 0x4D, 0x44, 0x48, 0x4D, 0x53].freeze # "YMDHMS"

        def validate_duration(_type, duration, want_val, collapse)
          return [-1, nil] if duration.nil?

          s = duration
          cur = 0
          isneg = false
          seq = 0
          secs = 0
          sec_frac = 0.0
          if collapse
            cur += 1 while blank_ch?(s.getbyte(cur) || 0)
          end
          if s.getbyte(cur) == 0x2D
            isneg = true
            cur += 1
          end
          # duration must start with 'P' (after sign)
          c = s.getbyte(cur) || 0
          cur += 1
          return [1, nil] if c != 0x50
          return [1, nil] if (s.getbyte(cur) || 0) == 0

          dur = new_value(XML_SCHEMAS_DURATION)
          dur.sec = 0.0
          while (s.getbyte(cur) || 0) != 0
            num = 0
            has_digits = false
            has_frac = false
            # input string should be empty or invalid date/time item
            return [1, nil] if seq >= 6

            # T designator must be present for time items
            if s.getbyte(cur) == 0x54
              return [1, nil] if seq > 3

              cur += 1
              seq = 3
            elsif seq == 3
              return [1, nil]
            end
            # Parse integral part.
            while (c = s.getbyte(cur) || 0) >= 0x30 && c <= 0x39
              digit = c - 0x30
              return [1, nil] if num > LONG_MAX / 10

              num *= 10
              return [1, nil] if num > LONG_MAX - digit

              num += digit
              has_digits = true
              cur += 1
            end
            if s.getbyte(cur) == 0x2E
              # Parse fractional part.
              mult = 1.0
              cur += 1
              has_frac = true
              while (c = s.getbyte(cur) || 0) >= 0x30 && c <= 0x39
                mult /= 10.0
                sec_frac += (c - 0x30) * mult
                has_digits = true
                cur += 1
              end
            end
            while (s.getbyte(cur) || 0) != DURATION_DESIG[seq]
              seq += 1
              # No T designator or invalid char.
              return [1, nil] if seq == 3 || seq == 6
            end
            cur += 1
            return [1, nil] if !has_digits || (has_frac && seq != 5)

            case seq
            when 0 # Year
              return [1, nil] if num > LONG_MAX / 12

              dur.mon = num * 12
            when 1 # Month
              return [1, nil] if dur.mon > LONG_MAX - num

              dur.mon += num
            when 2 # Day
              dur.day = num
            when 3 # Hour
              days = num / HOURS_PER_DAY
              return [1, nil] if dur.day > LONG_MAX - days

              dur.day += days
              secs = (num % HOURS_PER_DAY) * SECS_PER_HOUR
            when 4 # Minute
              days = num / MINS_PER_DAY
              return [1, nil] if dur.day > LONG_MAX - days

              dur.day += days
              secs += (num % MINS_PER_DAY) * SECS_PER_MIN
            when 5 # Second
              days = num / SECS_PER_DAY
              return [1, nil] if dur.day > LONG_MAX - days

              dur.day += days
              secs += num % SECS_PER_DAY
            end
            seq += 1
          end
          days = secs / SECS_PER_DAY
          return [1, nil] if dur.day > LONG_MAX - days

          dur.day += days
          dur.sec = (secs % SECS_PER_DAY) + sec_frac
          if isneg
            dur.mon = -dur.mon
            dur.day = -dur.day
            dur.sec = -dur.sec
          end
          [0, want_val ? dur : nil]
        end

        # xmlSchemaStrip: returns nil if no change was required
        def strip(value)
          return nil if value.nil?

          start = 0
          n = value.bytesize
          start += 1 while start < n && blank_ch?(value.getbyte(start))
          f = n
          e = n - 1
          e -= 1 while e > start && blank_ch?(value.getbyte(e))
          e += 1
          return nil if start == 0 && f == e

          value.byteslice(start, e - start)
        end

        # xmlSchemaWhiteSpaceReplace: returns nil if no change was required
        def white_space_replace(value)
          return nil if value.nil?
          return nil unless value.match?(/[\r\t\n]/)

          value.tr("\r\t\n", "   ")
        end

        # xmlSchemaCollapseString: returns nil if no change was required
        def collapse_string(value)
          return nil if value.nil?

          n = value.bytesize
          start = 0
          start += 1 while start < n && blank_ch?(value.getbyte(start))
          e = start
          col = 0
          while e < n
            c = value.getbyte(e)
            if c == 0x20 && blank_ch?(value.getbyte(e + 1) || 0)
              col = e - start
              break
            elsif c == 0xA || c == 0x9 || c == 0xD
              col = e - start
              break
            end
            e += 1
          end
          if col == 0
            f = e
            e -= 1
            e -= 1 while e > start && blank_ch?(value.getbyte(e))
            e += 1
            return nil if start == 0 && f == e

            return value.byteslice(start, e - start)
          end
          # collapse runs of blanks into single spaces, drop trailing blanks
          rest = value.byteslice(start, n - start)
          head = rest.byteslice(0, col)
          tail = rest.byteslice(col..)
          out = head + tail.gsub(/[ \t\n\r]+/, " ")
          out.chomp!(" ")
          out
        end

        # xmlSchemaValAtomicListNode. Returns [nb_values_or_-1, ret_val(always nil)].
        def val_atomic_list_node(type, value, _want_ret, node)
          return [-1, nil] if value.nil?

          items = value.split(/[ \t\n\r]+/)
          items.shift if !items.empty? && items[0].empty?
          nb_values = items.size
          return [0, nil] if nb_values == 0

          tmp = 0
          items.each do |item|
            tmp, = val_predef_type_node(type, item, false, node)
            break if tmp != 0
          end
          # TODO what return value ? c.f. bug #158628
          return [nb_values, nil] if tmp == 0

          [-1, nil]
        end

        # xmlSchemaParseUInt: returns [ret, new_cur] and fills the decimal
        def parse_u_int(s, cur, decimal)
          c = s.getbyte(cur) || 0
          return [-2, cur] unless c >= 0x30 && c <= 0x39

          cur += 1 while s.getbyte(cur) == 0x30 # ignore leading zeroes
          # back up in case there is nothing after the leading zeroes
          c = s.getbyte(cur) || 0
          cur -= 1 unless c >= 0x30 && c <= 0x39
          tmp = cur
          i = 0
          while (c = s.getbyte(tmp) || 0) >= 0x30 && c <= 0x39
            i += 1
            tmp += 1
          end
          decimal.fractional_places = 1
          decimal.integral_places = i
          decimal.str = +"+#{s.byteslice(cur, i)}.0"
          [i, tmp]
        end

        # xmlSchemaCheckLanguageType
        def check_language_type(value)
          return 0 if value.nil?

          first = true
          len = 0
          value.each_byte do |c|
            unless (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || c == 0x2D ||
                (!first && c >= 0x30 && c <= 0x39)
              return 0
            end

            if c == 0x2D
              return 0 if len < 1 || len > 8

              len = 0
              first = false
            else
              len += 1
            end
          end
          return 0 if len < 1 || len > 8

          1
        end

        MAX_LONG_DEC = TmpDecimal.new("+9223372036854775807.0", 19, 1)
        MIN_LONG_DEC = TmpDecimal.new("-9223372036854775808.0", 19, 1)
        MAX_ULONG_DEC = TmpDecimal.new("+18446744073709551615.0", 20, 1)
        MAX_UINT_DEC = TmpDecimal.new("+4294967295.0", 10, 1)

        # xmlSchemaValAtomicType. Returns [ret, val].
        def val_atomic_type(type, value, want_val, node, flags, ws, norm_on_the_fly, apply_norm,
          create_string_value)
          init_types unless @initialized
          return [-1, nil] if type.nil?

          # validating a non existent text node is similar to validating an empty one.
          value = "" if value.nil?
          norm = nil
          if flags == 0
            bt = type.built_in_type
            if bt != XML_SCHEMAS_STRING && bt != XML_SCHEMAS_ANYTYPE && bt != XML_SCHEMAS_ANYSIMPLETYPE
              norm = bt == XML_SCHEMAS_NORMSTRING ? white_space_replace(value) : collapse_string(value)
              value = norm unless norm.nil?
            end
          end
          ret = 0
          v = nil
          s = value

          case type.built_in_type
          when XML_SCHEMAS_UNKNOWN
            return [-1, nil]
          when XML_SCHEMAS_ANYTYPE, XML_SCHEMAS_ANYSIMPLETYPE
            if create_string_value && want_val
              v = new_value(XML_SCHEMAS_ANYSIMPLETYPE)
              v.str = value.dup
            end
            return [0, v]
          when XML_SCHEMAS_STRING
            unless norm_on_the_fly
              if ws == XML_SCHEMA_WHITESPACE_REPLACE
                return [1, nil] if s.match?(/[\r\n\t]/)
              elsif ws == XML_SCHEMA_WHITESPACE_COLLAPSE
                return [1, nil] if s.match?(/[\r\n\t]|  /)
              end
            end
            if create_string_value && want_val
              if apply_norm
                if ws == XML_SCHEMA_WHITESPACE_COLLAPSE
                  norm = collapse_string(value)
                elsif ws == XML_SCHEMA_WHITESPACE_REPLACE
                  norm = white_space_replace(value)
                end
                value = norm unless norm.nil?
              end
              v = new_value(XML_SCHEMAS_STRING)
              v.str = value.dup
            end
            return [0, v]
          when XML_SCHEMAS_NORMSTRING
            if norm_on_the_fly
              if apply_norm
                norm = if ws == XML_SCHEMA_WHITESPACE_COLLAPSE
                  collapse_string(value)
                else
                  white_space_replace(value)
                end
                value = norm unless norm.nil?
              end
            elsif s.match?(/[\r\n\t]/)
              return [1, nil]
            end
            if want_val
              v = new_value(XML_SCHEMAS_NORMSTRING)
              v.str = value.dup
            end
            return [0, v]
          when XML_SCHEMAS_DECIMAL
            return [1, nil] if s.empty?

            cur = 0
            # xs:decimal has a whitespace-facet value of 'collapse'.
            if norm_on_the_fly
              cur += 1 while blank_ch?(s.getbyte(cur) || 0)
            end
            # First we handle an optional sign.
            sign = "+"
            c = s.getbyte(cur)
            if c == 0x2D
              sign = "-"
              cur += 1
            elsif c == 0x2B
              cur += 1
            end
            # Disallow: "", "-", "- "
            return [1, nil] if (s.getbyte(cur) || 0) == 0

            # Skip leading zeroes.
            cur += 1 while s.getbyte(cur) == 0x30
            num_start = cur
            integral_places = 0
            fractional_places = 0
            while (c = s.getbyte(cur) || 0) >= 0x30 && c <= 0x39
              cur += 1
              integral_places += 1
            end
            cur += 1 if s.getbyte(cur) == 0x2E
            while (c = s.getbyte(cur) || 0) >= 0x30 && c <= 0x39
              cur += 1
              fractional_places += 1
            end
            # disallow "."
            if fractional_places == 0 && integral_places == 0 &&
                (num_start == 0 || s.getbyte(num_start - 1) != 0x30)
              return [1, nil]
            end

            num_end = cur
            # find if there are trailing FRACTIONAL zeroes, and deal with them if necessary
            while num_end > num_start && fractional_places > 0 && s.getbyte(num_end - 1) == 0x30
              num_end -= 1
              fractional_places -= 1
            end
            if norm_on_the_fly
              cur += 1 while blank_ch?(s.getbyte(cur) || 0)
            end
            return [1, nil] if (s.getbyte(cur) || 0) != 0 # error if any extraneous chars

            if want_val
              v = new_value(XML_SCHEMAS_DECIMAL)
              # create a standardized representation
              if integral_places == 0
                ipart = "0"
                integral_places = 1
              else
                ipart = s.byteslice(num_start, integral_places)
              end
              if fractional_places == 0
                fpart = "0"
                fractional_places = 1
              else
                fpart = s.byteslice(num_end - fractional_places, fractional_places)
              end
              v.str = +"#{sign}#{ipart}.#{fpart}"
              v.integral_places = integral_places
              v.fractional_places = fractional_places
            end
            return [0, v]
          when XML_SCHEMAS_TIME, XML_SCHEMAS_GDAY, XML_SCHEMAS_GMONTH, XML_SCHEMAS_GMONTHDAY,
            XML_SCHEMAS_GYEAR, XML_SCHEMAS_GYEARMONTH, XML_SCHEMAS_DATE, XML_SCHEMAS_DATETIME
            return validate_dates(type.built_in_type, value, want_val, norm_on_the_fly)
          when XML_SCHEMAS_DURATION
            return validate_duration(type, value, want_val, norm_on_the_fly)
          when XML_SCHEMAS_FLOAT, XML_SCHEMAS_DOUBLE
            return val_float(type, s, want_val, norm_on_the_fly)
          when XML_SCHEMAS_BOOLEAN
            cur = 0
            if norm_on_the_fly
              cur += 1 while blank_ch?(s.getbyte(cur) || 0)
              case s.getbyte(cur)
              when 0x30
                ret = 0
                cur += 1
              when 0x31
                ret = 1
                cur += 1
              when 0x74 # 't'
                return [1, nil] unless s.byteslice(cur + 1, 3) == "rue"

                cur += 4
                ret = 1
              when 0x66 # 'f'
                return [1, nil] unless s.byteslice(cur + 1, 4) == "alse"

                cur += 5
                ret = 0
              else
                return [1, nil]
              end
              if (s.getbyte(cur) || 0) != 0
                cur += 1 while blank_ch?(s.getbyte(cur) || 0)
                return [1, nil] if (s.getbyte(cur) || 0) != 0
              end
            else
              case s
              when "0", "false" then ret = 0
              when "1", "true" then ret = 1
              else return [1, nil]
              end
            end
            if want_val
              v = new_value(XML_SCHEMAS_BOOLEAN)
              v.b = ret
            end
            return [0, v]
          when XML_SCHEMAS_TOKEN
            if !norm_on_the_fly && (s.match?(/[\r\n\t]|  | \z/))
              return [1, nil]
            end
            if want_val
              v = new_value(XML_SCHEMAS_TOKEN)
              v.str = value.dup
            end
            return [0, v]
          when XML_SCHEMAS_LANGUAGE
            if norm.nil? && norm_on_the_fly
              norm = collapse_string(value)
              value = norm unless norm.nil?
            end
            if check_language_type(value) == 1
              if want_val
                v = new_value(XML_SCHEMAS_LANGUAGE)
                v.str = value.dup
              end
              return [0, v]
            end
            return [1, nil]
          when XML_SCHEMAS_NMTOKEN
            if validate_nm_token(value, 1) == 0
              if want_val
                v = new_value(XML_SCHEMAS_NMTOKEN)
                v.str = value.dup
              end
              return [0, v]
            end
            return [1, nil]
          when XML_SCHEMAS_NMTOKENS
            ret, = val_atomic_list_node(@builtin[XML_SCHEMAS_NMTOKEN], value, want_val, node)
            ret = ret > 0 ? 0 : 1
            return [ret, nil]
          when XML_SCHEMAS_NAME
            ret = validate_name(value, 1)
            if ret == 0 && want_val
              v = new_value(XML_SCHEMAS_NAME)
              st = 0
              st += 1 while blank_ch?(s.getbyte(st) || 0)
              e = st
              e += 1 while (c = s.getbyte(e) || 0) != 0 && !blank_ch?(c)
              v.str = s.byteslice(st, e - st)
            end
            return [ret, v]
          when XML_SCHEMAS_QNAME
            uri = nil
            local = nil
            ret = validate_q_name(value, 1)
            return [ret, nil] if ret != 0

            unless node.nil?
              local, prefix = Tree.split_qname2(value)
              ns = Tree.search_ns(node.doc, node, prefix)
              return [1, nil] if ns.nil? && !prefix.nil?

              uri = ns.href unless ns.nil?
            end
            if want_val
              v = new_value(XML_SCHEMAS_QNAME)
              v.str = local.nil? ? value.dup : local
              v.uri = uri.dup unless uri.nil?
            end
            return [ret, v]
          when XML_SCHEMAS_NCNAME
            ret = validate_nc_name(value, 1)
            if ret == 0 && want_val
              v = new_value(XML_SCHEMAS_NCNAME)
              v.str = value.dup
            end
            return [ret, v]
          when XML_SCHEMAS_ID
            ret = validate_nc_name(value, 1)
            if ret == 0 && want_val
              v = new_value(XML_SCHEMAS_ID)
              v.str = value.dup
            end
            if ret == 0 && !node.nil? && node.type == ATTRIBUTE_NODE
              attr = node
              # NOTE: the IDness might have already be declared in the DTD
              if attr.atype != ATTRIBUTE_ID
                stripped = strip(value)
                res = Tree.add_id(attr, stripped || value)
                if res < 0
                  return [-1, v]
                elsif res == 0
                  ret = 2
                end
              end
            end
            return [ret, v]
          when XML_SCHEMAS_IDREF
            ret = validate_nc_name(value, 1)
            if ret == 0 && want_val
              v = new_value(XML_SCHEMAS_IDREF)
              v.str = value.dup
            end
            if ret == 0 && !node.nil? && node.type == ATTRIBUTE_NODE
              stripped = strip(value)
              add_ref(node.doc, stripped || value, node)
              node.atype = ATTRIBUTE_IDREF
            end
            return [ret, v]
          when XML_SCHEMAS_IDREFS
            ret, = val_atomic_list_node(@builtin[XML_SCHEMAS_IDREF], value, want_val, node)
            ret = ret < 0 ? 2 : 0
            node.atype = ATTRIBUTE_IDREFS if ret == 0 && !node.nil? && node.type == ATTRIBUTE_NODE
            return [ret, nil]
          when XML_SCHEMAS_ENTITY
            ret = validate_nc_name(value, 1)
            ret = 3 if node.nil? || node.doc.nil?
            if ret == 0
              stripped = strip(value)
              ent = Tree.get_doc_entity(node.doc, stripped || value)
              ret = 4 if ent.nil? || ent.etype != EXTERNAL_GENERAL_UNPARSED_ENTITY
            end
            # (ret == 0) && (val != NULL): TODO in libxml2, no value is computed
            node.atype = ATTRIBUTE_ENTITY if ret == 0 && !node.nil? && node.type == ATTRIBUTE_NODE
            return [ret, nil]
          when XML_SCHEMAS_ENTITIES
            return [3, nil] if node.nil? || node.doc.nil?

            ret, = val_atomic_list_node(@builtin[XML_SCHEMAS_ENTITY], value, want_val, node)
            ret = ret <= 0 ? 1 : 0
            node.atype = ATTRIBUTE_ENTITIES if ret == 0 && node.type == ATTRIBUTE_NODE
            return [ret, nil]
          when XML_SCHEMAS_NOTATION
            uri = nil
            local = nil
            ret = validate_q_name(value, 1)
            if ret == 0 && !node.nil?
              local, prefix = Tree.split_qname2(value)
              unless prefix.nil?
                ns = Tree.search_ns(node.doc, node, prefix)
                if ns.nil?
                  ret = 1
                elsif want_val
                  uri = ns.href.dup
                end
              end
              local = nil if !local.nil? && (!want_val || ret != 0)
            end
            ret = 3 if node.nil? || node.doc.nil?
            if ret == 0
              # xmlValidateNotationUse(NULL, doc, value): -1 without an internal subset,
              # 1 otherwise (without a validation context an undeclared notation is accepted)
              ret = node.doc.int_subset.nil? ? 1 : 0
            end
            if ret == 0 && want_val
              v = new_value(XML_SCHEMAS_NOTATION)
              v.str = local.nil? ? value.dup : local
              v.uri = uri unless uri.nil?
            end
            return [ret, v]
          when XML_SCHEMAS_ANYURI
            unless s.empty?
              if norm.nil? && norm_on_the_fly
                norm = collapse_string(value)
                value = norm unless norm.nil?
              end
              tmpval = value.b.gsub(/[\x00-\x20\x7F-\xFF<>"{}|\\^`']/n, "_")
              return [1, nil] unless parse_uri_ok(tmpval)
            end
            if want_val
              v = new_value(XML_SCHEMAS_ANYURI)
              v.str = value.dup
            end
            return [0, v]
          when XML_SCHEMAS_HEXBINARY
            cur = 0
            if norm_on_the_fly
              cur += 1 while blank_ch?(s.getbyte(cur) || 0)
            end
            start = cur
            i = 0
            while (c = s.getbyte(cur) || 0) != 0 &&
                ((c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66))
              i += 1
              cur += 1
            end
            if norm_on_the_fly
              cur += 1 while blank_ch?(s.getbyte(cur) || 0)
            end
            return [1, nil] if (s.getbyte(cur) || 0) != 0
            return [1, nil] if i.odd?

            if want_val
              v = new_value(XML_SCHEMAS_HEXBINARY)
              # Copy only the normalized piece.
              v.str = s.byteslice(start, i).upcase
              v.total = i / 2 # number of octets
            end
            return [0, v]
          when XML_SCHEMAS_BASE64BINARY
            return val_base64(s, want_val)
          when XML_SCHEMAS_INTEGER, XML_SCHEMAS_PINTEGER, XML_SCHEMAS_NPINTEGER,
            XML_SCHEMAS_NINTEGER, XML_SCHEMAS_NNINTEGER, XML_SCHEMAS_LONG, XML_SCHEMAS_BYTE,
            XML_SCHEMAS_SHORT, XML_SCHEMAS_INT, XML_SCHEMAS_UINT, XML_SCHEMAS_ULONG,
            XML_SCHEMAS_USHORT, XML_SCHEMAS_UBYTE
            return val_integer(type, s, want_val, norm_on_the_fly)
          end
          [ret, v]
        end

        # the float/double branch of xmlSchemaValAtomicType
        def val_float(type, s, want_val, norm_on_the_fly)
          is_float = type.equal?(@float_def)
          cur = 0
          neg = false
          digits_before = 0
          digits_after = 0
          if norm_on_the_fly
            cur += 1 while blank_ch?(s.getbyte(cur) || 0)
          end
          if s.byteslice(cur, 3) == "NaN"
            cur += 3
            return [1, nil] if (s.getbyte(cur) || 0) != 0

            v = nil
            if want_val
              v = new_value(is_float ? XML_SCHEMAS_FLOAT : XML_SCHEMAS_DOUBLE)
              is_float ? (v.f = Float::NAN) : (v.d = Float::NAN)
            end
            return [0, v]
          end
          if s.getbyte(cur) == 0x2D
            neg = true
            cur += 1
          end
          if s.byteslice(cur, 3) == "INF"
            cur += 3
            return [1, nil] if (s.getbyte(cur) || 0) != 0

            v = nil
            if want_val
              inf = neg ? -Float::INFINITY : Float::INFINITY
              v = new_value(is_float ? XML_SCHEMAS_FLOAT : XML_SCHEMAS_DOUBLE)
              is_float ? (v.f = inf) : (v.d = inf)
            end
            return [0, v]
          end
          cur += 1 if !neg && s.getbyte(cur) == 0x2B
          c = s.getbyte(cur) || 0
          return [1, nil] if c == 0 || c == 0x2B || c == 0x2D

          while (c = s.getbyte(cur) || 0) >= 0x30 && c <= 0x39
            cur += 1
            digits_before += 1
          end
          if c == 0x2E
            cur += 1
            while (c = s.getbyte(cur) || 0) >= 0x30 && c <= 0x39
              cur += 1
              digits_after += 1
            end
          end
          return [1, nil] if digits_before == 0 && digits_after == 0

          c = s.getbyte(cur) || 0
          if c == 0x65 || c == 0x45
            cur += 1
            c = s.getbyte(cur) || 0
            cur += 1 if c == 0x2D || c == 0x2B
            cur += 1 while (c = s.getbyte(cur) || 0) >= 0x30 && c <= 0x39
          end
          if norm_on_the_fly
            cur += 1 while blank_ch?(s.getbyte(cur) || 0)
          end
          return [1, nil] if (s.getbyte(cur) || 0) != 0

          v = nil
          if want_val
            ok, num = c_sscanf_double(s)
            return [1, nil] unless ok

            if is_float
              v = new_value(XML_SCHEMAS_FLOAT)
              v.f = strtof_round(num[0], num[1])
            else
              v = new_value(XML_SCHEMAS_DOUBLE)
              v.d = num[0]
            end
          end
          [0, v]
        end

        SCANF_FLOAT_RE = /\A[ \t\n\v\f\r]*([+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+))([eE][+-]?)?([0-9]*)/n

        # sscanf(value, "%lf") as implemented by glibc: returns [ok, [double, text]]. An
        # incomplete exponent ("1e", "1e+") is ignored and the mantissa converted (glibc returns 1).
        def c_sscanf_double(s)
          m = SCANF_FLOAT_RE.match(s.b)
          return [false, nil] if m.nil?

          text = m[1]
          text = "#{text}e#{m[2][1..]}#{m[3]}" if m[2] && !m[3].empty?
          [true, [c_strtod(text), text]]
        end

        # strtod() of a well-formed decimal floating constant (correctly rounded)
        def c_strtod(text)
          if text.bytesize > 20 || text.match?(/e[+-]?\d{3}/i)
            # avoid Ruby's "Float out of range" warnings; the result is still correctly rounded
            verbose = $VERBOSE
            begin
              $VERBOSE = nil
              text.to_f
            ensure
              $VERBOSE = verbose
            end
          else
            text.to_f
          end
        end

        FLT_MAX = 3.4028234663852886e+38
        FLT_MAX_ROUND = 3.4028235677973366e+38 # FLT_MAX + ulp/2: rounds (to even) to infinity

        # (float) conversion of a double: round-to-nearest-even to single precision (Array#pack
        # would turn every finite value above FLT_MAX into infinity)
        def to_single(d)
          if d.finite? && d.abs > FLT_MAX
            return d.abs >= FLT_MAX_ROUND ? (d > 0 ? Float::INFINITY : -Float::INFINITY) : (d > 0 ? FLT_MAX : -FLT_MAX)
          end

          [d].pack("e").unpack1("e")
        end

        # strtof(): correctly rounded decimal -> single. Rounding the (correctly rounded) double
        # can only differ from direct rounding when the double lies exactly half-way between two
        # floats; then the exact decimal value decides.
        def strtof_round(d, text)
          f = to_single(d)
          if d.abs == FLT_MAX_ROUND
            # half-way between FLT_MAX and "2^128": the exact value decides
            big = decimal_to_rational(text).abs >= FLT_MAX_ROUND.to_r
            return big ? (d > 0 ? Float::INFINITY : -Float::INFINITY) : (d > 0 ? FLT_MAX : -FLT_MAX)
          end
          return f if f == d || !d.finite? || !f.finite?

          # the neighbour float on the other side of d
          bits = [f].pack("e").unpack1("L<")
          g = if d.abs > f.abs
            [bits + 1].pack("L<").unpack1("e")
          elsif (bits & 0x7fffffff) != 0
            [bits - 1].pack("L<").unpack1("e")
          end
          return f if g.nil? || !g.finite? || (d - f).abs != (g - d).abs

          exact = decimal_to_rational(text)
          mid = d.to_r
          return f if exact == mid

          lo, hi = f < g ? [f, g] : [g, f]
          exact < mid ? lo : hi
        end

        def decimal_to_rational(text)
          m = /\A([+-]?)(\d*)(?:\.(\d*))?(?:[eE]([+-]?\d+))?\z/.match(text)
          sign = m[1] == "-" ? -1 : 1
          digits = "#{m[2]}#{m[3]}"
          exp = m[4].to_i - (m[3] || "").size
          n = digits.to_i * sign
          exp >= 0 ? Rational(n * 10**exp, 1) : Rational(n, 10**-exp)
        end

        # the base64Binary branch of xmlSchemaValAtomicType
        def val_base64(s, want_val)
          i = 0
          pad = 0
          cur = 0
          n = s.bytesize
          while cur < n
            decc = base64_decode(s.getbyte(cur))
            if decc < 0
              nil
            elsif decc < 64
              i += 1
            else
              break
            end
            cur += 1
          end
          while cur < n
            decc = base64_decode(s.getbyte(cur))
            return [1, nil] if decc >= 0 && decc < 64

            pad += 1 if decc == 64
            cur += 1
          end
          total = 3 * (i / 4)
          if pad == 0
            return [1, nil] if i % 4 != 0
          elsif pad == 1
            return [1, nil] if i % 4 != 3

            decc = base64_decode(s.getbyte(cur) || 0)
            while decc < 0 || decc > 63
              cur -= 1
              decc = base64_decode(s.getbyte(cur) || 0)
            end
            # 16bits in 24bits means 2 pad bits: nnnnnn nnmmmm mmmm00
            return [1, nil] if (decc & ~0x3c) != 0

            total += 2
          elsif pad == 2
            return [1, nil] if i % 4 != 2

            decc = base64_decode(s.getbyte(cur) || 0)
            while decc < 0 || decc > 63
              cur -= 1
              decc = base64_decode(s.getbyte(cur) || 0)
            end
            # 8bits in 12bits means 4 pad bits: nnnnnn nn0000
            return [1, nil] if (decc & ~0x30) != 0

            total += 1
          else
            return [1, nil]
          end
          v = nil
          if want_val
            v = new_value(XML_SCHEMAS_BASE64BINARY)
            v.str = s.b.delete("^A-Za-z0-9+/=").force_encoding(Encoding::UTF_8)
            v.total = total
          end
          [0, v]
        end

        # the integer branch of xmlSchemaValAtomicType
        def val_integer(type, s, want_val, norm_on_the_fly)
          cur = 0
          sign = 0x2B
          decimal = SchemaVal.new(type.built_in_type)
          if norm_on_the_fly
            cur += 1 while blank_ch?(s.getbyte(cur) || 0)
          end
          c = s.getbyte(cur)
          if c == 0x2D
            sign = 0x2D
            cur += 1
          elsif c == 0x2B
            cur += 1
          end
          ret, cur = parse_u_int(s, cur, decimal)
          return [1, nil] if ret < 0

          # add sign
          decimal.str.setbyte(0, sign)
          if norm_on_the_fly
            cur += 1 while blank_ch?(s.getbyte(cur) || 0)
          end
          return [1, nil] if (s.getbyte(cur) || 0) != 0

          case type.built_in_type
          when XML_SCHEMAS_NPINTEGER
            return [1, nil] if val_decimal_compare_with_integer(decimal, 0) > 0
          when XML_SCHEMAS_PINTEGER
            return [1, nil] if sign == 0x2D
            return [1, nil] if val_decimal_compare_with_integer(decimal, 0) <= 0
          when XML_SCHEMAS_NINTEGER
            return [1, nil] if val_decimal_compare_with_integer(decimal, 0) >= 0
          when XML_SCHEMAS_NNINTEGER
            return [1, nil] if val_decimal_compare_with_integer(decimal, 0) < 0
          when XML_SCHEMAS_LONG
            return [1, nil] if val_decimal_compare(decimal, MAX_LONG_DEC) > 0
            return [1, nil] if val_decimal_compare(decimal, MIN_LONG_DEC) < 0
          when XML_SCHEMAS_ULONG
            return [1, nil] if val_decimal_compare(decimal, MAX_ULONG_DEC) > 0
            return [1, nil] if val_decimal_compare_with_integer(decimal, 0) < 0
          when XML_SCHEMAS_INT
            return [1, nil] if val_decimal_compare_with_integer(decimal, 0x7fffffff) > 0
            return [1, nil] if val_decimal_compare_with_integer(decimal, -0x7fffffff - 1) < 0
          when XML_SCHEMAS_SHORT
            return [1, nil] if val_decimal_compare_with_integer(decimal, 0x7fff) > 0
            return [1, nil] if val_decimal_compare_with_integer(decimal, -0x8000) < 0
          when XML_SCHEMAS_BYTE
            return [1, nil] if val_decimal_compare_with_integer(decimal, 0x7f) > 0
            return [1, nil] if val_decimal_compare_with_integer(decimal, -0x80) < 0
          when XML_SCHEMAS_UINT
            return [1, nil] if val_decimal_compare(decimal, MAX_UINT_DEC) > 0
            return [1, nil] if val_decimal_compare_with_integer(decimal, 0) < 0
          when XML_SCHEMAS_USHORT
            return [1, nil] if val_decimal_compare_with_integer(decimal, 0xffff) > 0
            return [1, nil] if val_decimal_compare_with_integer(decimal, 0) < 0
          when XML_SCHEMAS_UBYTE
            return [1, nil] if val_decimal_compare_with_integer(decimal, 0xff) > 0
            return [1, nil] if val_decimal_compare_with_integer(decimal, 0) < 0
          end
          [0, want_val ? decimal : nil]
        end

        # xmlAddRef(NULL, doc, value, attr): delegates to Pure::Valid (valid.rb) when loaded;
        # entries of doc.refs are [value, attr, name, lineno] like there
        def add_ref(doc, value, attr)
          return Valid.add_ref(nil, doc, value, attr) if defined?(Valid) && Valid.respond_to?(:add_ref)
          return nil if doc.nil? || value.nil? || attr.nil?

          ref = [value.dup, attr, nil, Tree.get_line_no(attr.parent)]
          ((doc.refs ||= {})[value] ||= []) << ref
          ref
        end

        # xmlSchemaValPredefTypeNode. Returns [ret, val].
        def val_predef_type_node(type, value, want_val, node)
          val_atomic_type(type, value, want_val, node, 0, XML_SCHEMA_WHITESPACE_UNKNOWN, true, true, false)
        end

        # xmlSchemaValPredefTypeNodeNoNorm. Returns [ret, val].
        def val_predef_type_node_no_norm(type, value, want_val, node)
          val_atomic_type(type, value, want_val, node, 1, XML_SCHEMA_WHITESPACE_UNKNOWN, true, false, true)
        end

        # xmlSchemaValidatePredefinedType. Returns [ret, val].
        def validate_predefined_type(type, value, want_val = true)
          val_predef_type_node(type, value, want_val, nil)
        end
      end
    end
  end
end

