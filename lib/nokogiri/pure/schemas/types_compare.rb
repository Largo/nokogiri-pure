# frozen_string_literal: true

# Port of libxml2 2.13.9 xmlschemastypes.c, second half: value comparison, date arithmetic,
# facet validation and canonical representations.
module Nokogiri
  module Pure
    module Schemas
      module Types
        extend self

        # C integer division (truncates toward zero)
        def cdiv(a, b)
          q = a.abs / b.abs
          (a < 0) == (b < 0) ? q : -q
        end
        private :cdiv

        # FQUOTIENT(a,b): floor((double)a/(double)b) (returned as an Integer)
        def fquotient(a, b) = (a.to_f / b.to_f).floor

        # MODULO(a,b): a - FQUOTIENT(a,b) * b, computed in double precision
        def modulo(a, b) = a.to_f - (fquotient(a, b) * b.to_f)

        # FQUOTIENT_RANGE / MODULO_RANGE
        def fquotient_range(a, low, high) = fquotient(a - low, high - low)
        def modulo_range(a, low, high) = modulo(a - low, high - low) + low

        # (unsigned int) cast of a non-negative double
        def c_uint(d) = d.to_i & 0xFFFFFFFF
        private :c_uint

        DECIMAL_TYPES = [
          XML_SCHEMAS_DECIMAL, XML_SCHEMAS_INTEGER, XML_SCHEMAS_NPINTEGER, XML_SCHEMAS_NINTEGER,
          XML_SCHEMAS_NNINTEGER, XML_SCHEMAS_PINTEGER, XML_SCHEMAS_INT, XML_SCHEMAS_UINT,
          XML_SCHEMAS_LONG, XML_SCHEMAS_ULONG, XML_SCHEMAS_SHORT, XML_SCHEMAS_USHORT,
          XML_SCHEMAS_BYTE, XML_SCHEMAS_UBYTE
        ].freeze
        DATE_TYPES = [
          XML_SCHEMAS_DATETIME, XML_SCHEMAS_TIME, XML_SCHEMAS_GDAY, XML_SCHEMAS_GMONTH,
          XML_SCHEMAS_GMONTHDAY, XML_SCHEMAS_GYEAR, XML_SCHEMAS_DATE, XML_SCHEMAS_GYEARMONTH
        ].freeze
        STRING_TYPES = [
          XML_SCHEMAS_ANYSIMPLETYPE, XML_SCHEMAS_STRING, XML_SCHEMAS_NORMSTRING, XML_SCHEMAS_TOKEN,
          XML_SCHEMAS_LANGUAGE, XML_SCHEMAS_NMTOKEN, XML_SCHEMAS_NAME, XML_SCHEMAS_NCNAME,
          XML_SCHEMAS_ID, XML_SCHEMAS_IDREF, XML_SCHEMAS_ENTITY, XML_SCHEMAS_ANYURI
        ].freeze

        # xmlSchemaCompareDecimals
        def compare_decimals(x, y)
          res = val_decimal_compare(x, y)
          return 1 if res > 0
          return -1 if res < 0

          0
        end

        DAY_RANGE = [
          [0, 28, 59, 89, 120, 150, 181, 212, 242, 273, 303, 334],
          [0, 31, 62, 92, 123, 153, 184, 215, 245, 276, 306, 337]
        ].freeze

        # xmlSchemaCompareDurations
        def compare_durations(x, y)
          return -2 if x.nil? || y.nil?

          invert = 1
          # months
          mon = x.mon - y.mon
          # seconds
          sec = x.sec - y.sec
          carry = (sec / SECS_PER_DAY).truncate
          sec -= carry.to_f * SECS_PER_DAY
          # days
          day = x.day - y.day + carry
          # easy test
          if mon == 0
            if day == 0
              return 0 if sec == 0.0
              return -1 if sec < 0.0

              return 1
            end
            return day < 0 ? -1 : 1
          end

          if mon > 0
            return 1 if day >= 0 && sec >= 0.0

            xmon = mon
            xday = -day
          elsif day <= 0 && sec <= 0.0
            return -1
          else
            invert = -1
            xmon = -mon
            xday = day
          end
          myear = xmon / 12
          if myear == 0
            minday = 0
            maxday = 0
          else
            return -2 if myear > LONG_MAX / 366

            # FIXME: This doesn't take leap year exceptions every 100/400 years into account.
            maxday = 365 * myear + (myear + 3) / 4
            # FIXME: Needs to be calculated separately
            minday = maxday - 1
          end
          xmon %= 12
          minday += DAY_RANGE[0][xmon]
          maxday += DAY_RANGE[1][xmon]
          return 0 if maxday == minday && maxday == xday # can this really happen ?
          return -invert if maxday < xday
          return invert if minday > xday

          # indeterminate
          2
        end

        # xmlSchemaDupVal
        def dup_val(v)
          ret = v.dup
          ret.next = nil
          ret
        end

        # xmlSchemaCopyValue
        def copy_value(val)
          ret = nil
          prev = nil
          until val.nil?
            case val.type
            when XML_SCHEMAS_ANYTYPE, XML_SCHEMAS_IDREFS, XML_SCHEMAS_ENTITIES, XML_SCHEMAS_NMTOKENS
              return nil
            end
            cur = dup_val(val)
            cur.str = val.str.dup unless val.str.nil?
            cur.uri = val.uri.dup unless val.uri.nil?
            if ret.nil?
              ret = cur
            else
              prev.next = cur
            end
            prev = cur
            val = val.next
          end
          ret
        end

        # _xmlSchemaDateAdd (the date fields of the result are C bitfields: mon:4, day:5,
        # hour:5, min:6)
        def date_add(dt, dur)
          return nil if dt.nil? || dur.nil?

          ret = new_value(dt.type)
          # make a copy so we don't alter the original value
          d = dup_val(dt)
          r = ret
          u = dur
          # normalization
          d.mon = 1 if d.mon == 0
          # normalize for time zone offset
          u.sec -= d.tzo * 60
          d.tzo = 0
          # normalization
          d.day = 1 if d.day == 0
          # month
          carry = d.mon + u.mon
          r.mon = c_uint(modulo_range(carry, 1, 13)) & 0xF
          carry = fquotient_range(carry, 1, 13)
          # year (may be modified later)
          r.year = d.year + carry
          if r.year == 0
            if d.year > 0
              r.year -= 1
            else
              r.year += 1
            end
          end
          # time zone
          r.tzo = d.tzo
          r.tz_flag = d.tz_flag
          # seconds
          r.sec = d.sec + u.sec
          carry = fquotient(r.sec.truncate, 60)
          r.sec = modulo(r.sec, 60.0) if r.sec != 0.0
          # minute
          carry += d.min
          r.min = c_uint(modulo(carry, 60)) & 0x3F
          carry = fquotient(carry, 60)
          # hours
          carry += d.hour
          r.hour = c_uint(modulo(carry, 24)) & 0x1F
          carry = fquotient(carry, 24)
          # days
          tempdays = if r.year != 0 && r.mon >= 1 && r.mon <= 12 && d.day > max_dayinmonth(r.year, r.mon)
            max_dayinmonth(r.year, r.mon)
          elsif d.day < 1
            1
          else
            d.day
          end
          tempdays += u.day + carry
          loop do
            if tempdays < 1
              tmon = modulo_range(r.mon - 1, 1, 13).to_i
              tyr = r.year + fquotient_range(r.mon - 1, 1, 13)
              tyr -= 1 if tyr == 0
              tmon = 1 if tmon < 1
              tmon = 12 if tmon > 12
              tempdays += max_dayinmonth(tyr, tmon)
              carry = -1
            elsif r.year != 0 && r.mon >= 1 && r.mon <= 12 && tempdays > max_dayinmonth(r.year, r.mon)
              tempdays -= max_dayinmonth(r.year, r.mon)
              carry = 1
            else
              break
            end
            temp = r.mon + carry
            r.mon = c_uint(modulo_range(temp, 1, 13)) & 0xF
            r.year += fquotient_range(temp, 1, 13)
            if r.year == 0
              if temp < 1
                r.year -= 1
              else
                r.year += 1
              end
            end
          end
          r.day = tempdays & 0x1F
          # adjust the date/time type to the date values
          if ret.type != XML_SCHEMAS_DATETIME
            if r.hour != 0 || r.min != 0 || r.sec != 0
              ret.type = XML_SCHEMAS_DATETIME
            elsif ret.type != XML_SCHEMAS_DATE
              if r.mon != 1 && r.day != 1
                ret.type = XML_SCHEMAS_DATE
              elsif ret.type != XML_SCHEMAS_GYEARMONTH && r.mon != 1
                ret.type = XML_SCHEMAS_GYEARMONTH
              end
            end
          end
          ret
        end

        # xmlSchemaDateNormalize
        def date_normalize(dt, offset)
          return nil if dt.nil?

          t = dt.type
          if (t != XML_SCHEMAS_TIME && t != XML_SCHEMAS_DATETIME && t != XML_SCHEMAS_DATE) || dt.tzo == 0
            return dup_val(dt)
          end

          dur = new_value(XML_SCHEMAS_DURATION)
          dur.sec -= offset
          date_add(dt, dur)
        end

        # _xmlSchemaDateCastYMToDays
        def date_cast_ym_to_days(dt)
          mon = dt.mon
          mon = 1 if mon <= 0 # normalization
          year = dt.year
          diy = (is_leap(year) ? DAY_IN_LEAP_YEAR_BY_MONTH : DAY_IN_YEAR_BY_MONTH)[mon - 1]
          if year <= 0
            (year * 365) + (cdiv(year + 1, 4) - cdiv(year + 1, 100) + cdiv(year + 1, 400)) + diy
          else
            ((year - 1) * 365) + (cdiv(year - 1, 4) - cdiv(year - 1, 100) + cdiv(year - 1, 400)) + diy
          end
        end

        # TIME_TO_NUMBER
        def time_to_number(dt)
          ((dt.hour * SECS_PER_HOUR) + (dt.min * SECS_PER_MIN) + (dt.tzo * SECS_PER_MIN)).to_f + dt.sec
        end

        DATE_MASKS = {
          XML_SCHEMAS_DATETIME => 0xf, XML_SCHEMAS_DATE => 0x7, XML_SCHEMAS_GYEAR => 0x1,
          XML_SCHEMAS_GMONTH => 0x2, XML_SCHEMAS_GDAY => 0x3, XML_SCHEMAS_GYEARMONTH => 0x3,
          XML_SCHEMAS_GMONTHDAY => 0x6, XML_SCHEMAS_TIME => 0x8
        }.freeze

        # xmlSchemaCompareDates
        def compare_dates(x, y)
          return -2 if x.nil? || y.nil?

          if x.year > LONG_MAX / 366 || x.year < cdiv(LONG_MIN, 366) ||
              y.year > LONG_MAX / 366 || y.year < cdiv(LONG_MIN, 366)
            # Possible overflow when converting to days.
            return -2
          end

          if x.tz_flag != 0
            if y.tz_flag == 0
              p1 = date_normalize(x, 0)
              return -2 if p1.nil?

              p1d = date_cast_ym_to_days(p1) + p1.day
              # normalize y + 14:00
              q1 = date_normalize(y, 14 * SECS_PER_HOUR)
              return -2 if q1.nil?

              q1d = date_cast_ym_to_days(q1) + q1.day
              if p1d < q1d
                return -1
              elsif p1d == q1d
                sec = time_to_number(p1) - time_to_number(q1)
                return -1 if sec < 0.0

                ret = 0
                # normalize y - 14:00
                q2 = date_normalize(y, -(14 * SECS_PER_HOUR))
                return -2 if q2.nil?

                q2d = date_cast_ym_to_days(q2) + q2.day
                if p1d > q2d
                  ret = 1
                elsif p1d == q2d
                  sec = time_to_number(p1) - time_to_number(q2)
                  ret = sec > 0.0 ? 1 : 2 # 2: indeterminate
                end
                return ret if ret != 0
              end
            end
          elsif y.tz_flag != 0
            q1 = date_normalize(y, 0)
            return -2 if q1.nil?

            q1d = date_cast_ym_to_days(q1) + q1.day
            # normalize x - 14:00
            p1 = date_normalize(x, -(14 * SECS_PER_HOUR))
            return -2 if p1.nil?

            p1d = date_cast_ym_to_days(p1) + p1.day
            if p1d < q1d
              return -1
            elsif p1d == q1d
              sec = time_to_number(p1) - time_to_number(q1)
              return -1 if sec < 0.0

              ret = 0
              # normalize x + 14:00
              p2 = date_normalize(x, 14 * SECS_PER_HOUR)
              return -2 if p2.nil?

              p2d = date_cast_ym_to_days(p2) + p2.day
              if p2d > q1d
                ret = 1
              elsif p2d == q1d
                sec = time_to_number(p2) - time_to_number(q1)
                ret = sec > 0.0 ? 1 : 2 # 2: indeterminate
              end
              return ret if ret != 0
            end
          end

          # if the same type then calculate the difference
          if x.type == y.type
            ret = 0
            q1 = date_normalize(y, 0)
            return -2 if q1.nil?

            q1d = date_cast_ym_to_days(q1) + q1.day
            p1 = date_normalize(x, 0)
            return -2 if p1.nil?

            p1d = date_cast_ym_to_days(p1) + p1.day
            if p1d < q1d
              ret = -1
            elsif p1d > q1d
              ret = 1
            else
              sec = time_to_number(p1) - time_to_number(q1)
              if sec < 0.0
                ret = -1
              elsif sec > 0.0
                ret = 1
              end
            end
            return ret
          end

          xmask = DATE_MASKS[x.type] || 0
          ymask = DATE_MASKS[y.type] || 0
          xor_mask = xmask ^ ymask # mark type differences
          and_mask = xmask & ymask # mark field specification

          # year
          if xor_mask & 1 != 0
            return 2 # indeterminate
          elsif and_mask & 1 != 0
            return -1 if x.year < y.year
            return 1 if x.year > y.year
          end
          # month
          if xor_mask & 2 != 0
            return 2 # indeterminate
          elsif and_mask & 2 != 0
            return -1 if x.mon < y.mon
            return 1 if x.mon > y.mon
          end
          # day
          if xor_mask & 4 != 0
            return 2 # indeterminate
          elsif and_mask & 4 != 0
            return -1 if x.day < y.day
            return 1 if x.day > y.day
          end
          # time
          if xor_mask & 8 != 0
            return 2 # indeterminate
          elsif and_mask & 8 != 0
            return -1 if x.hour < y.hour
            return 1 if x.hour > y.hour
            return -1 if x.min < y.min
            return 1 if x.min > y.min
            return -1 if x.sec < y.sec
            return 1 if x.sec > y.sec
          end
          0
        end

        def wsp_blank?(c) = c == 0x20 || c == 0x9 || c == 0xA || c == 0xD
        private :wsp_blank?

        # xmlSchemaComparePreserveReplaceStrings
        def compare_preserve_replace_strings(x, y, invert)
          xi = 0
          yi = 0
          loop do
            xc = x.getbyte(xi) || 0
            yc = y.getbyte(yi) || 0
            break if xc == 0 || yc == 0

            if yc == 0x9 || yc == 0xA || yc == 0xD
              if xc != 0x20
                return invert ? 1 : -1 if (xc - 0x20) < 0

                return invert ? -1 : 1
              end
            else
              tmp = xc - yc
              return invert ? 1 : -1 if tmp < 0
              return invert ? -1 : 1 if tmp > 0
            end
            xi += 1
            yi += 1
          end
          return invert ? -1 : 1 if (x.getbyte(xi) || 0) != 0
          return invert ? 1 : -1 if (y.getbyte(yi) || 0) != 0

          0
        end

        # xmlSchemaComparePreserveCollapseStrings
        def compare_preserve_collapse_strings(x, y, invert)
          xi = 0
          yi = 0
          # Skip leading blank chars of the collapsed string.
          yi += 1 while wsp_blank?(y.getbyte(yi) || 0)
          loop do
            xc = x.getbyte(xi) || 0
            yc = y.getbyte(yi) || 0
            break if xc == 0 || yc == 0

            if wsp_blank?(yc)
              if xc != 0x20
                # The yv character would have been replaced to 0x20.
                return invert ? 1 : -1 if (xc - 0x20) < 0

                return invert ? -1 : 1
              end
              xi += 1
              yi += 1
              # Skip contiguous blank chars of the collapsed string.
              yi += 1 while wsp_blank?(y.getbyte(yi) || 0)
            else
              tmp = xc - yc
              xi += 1
              yi += 1
              return invert ? 1 : -1 if tmp < 0
              return invert ? -1 : 1 if tmp > 0
            end
          end
          return invert ? -1 : 1 if (x.getbyte(xi) || 0) != 0

          if (y.getbyte(yi) || 0) != 0
            # Skip trailing blank chars of the collapsed string.
            yi += 1 while wsp_blank?(y.getbyte(yi) || 0)
            return invert ? 1 : -1 if (y.getbyte(yi) || 0) != 0
          end
          0
        end

        # xmlSchemaCompareReplaceCollapseStrings
        def compare_replace_collapse_strings(x, y, invert)
          xi = 0
          yi = 0
          # Skip leading blank chars of the collapsed string.
          yi += 1 while wsp_blank?(y.getbyte(yi) || 0)
          loop do
            xc = x.getbyte(xi) || 0
            yc = y.getbyte(yi) || 0
            break if xc == 0 || yc == 0

            if wsp_blank?(yc)
              unless wsp_blank?(xc)
                # The yv character would have been replaced to 0x20.
                return invert ? 1 : -1 if (xc - 0x20) < 0

                return invert ? -1 : 1
              end
              xi += 1
              yi += 1
              # Skip contiguous blank chars of the collapsed string.
              yi += 1 while wsp_blank?(y.getbyte(yi) || 0)
            else
              if wsp_blank?(xc)
                # The xv character would have been replaced to 0x20.
                return invert ? 1 : -1 if (0x20 - yc) < 0

                return invert ? -1 : 1
              end
              tmp = xc - yc
              xi += 1
              yi += 1
              return -1 if tmp < 0
              return 1 if tmp > 0
            end
          end
          return invert ? -1 : 1 if (x.getbyte(xi) || 0) != 0

          if (y.getbyte(yi) || 0) != 0
            # Skip trailing blank chars of the collapsed string.
            yi += 1 while wsp_blank?(y.getbyte(yi) || 0)
            return invert ? 1 : -1 if (y.getbyte(yi) || 0) != 0
          end
          0
        end

        # xmlSchemaCompareReplacedStrings
        def compare_replaced_strings(x, y)
          xi = 0
          yi = 0
          loop do
            xc = x.getbyte(xi) || 0
            yc = y.getbyte(yi) || 0
            break if xc == 0 || yc == 0

            if wsp_blank?(yc)
              return (xc - 0x20) < 0 ? -1 : 1 unless wsp_blank?(xc)
            else
              return (0x20 - yc) < 0 ? -1 : 1 if wsp_blank?(xc)

              tmp = xc - yc
              return -1 if tmp < 0
              return 1 if tmp > 0
            end
            xi += 1
            yi += 1
          end
          return 1 if (x.getbyte(xi) || 0) != 0
          return -1 if (y.getbyte(yi) || 0) != 0

          0
        end

        # xmlSchemaCompareNormStrings
        def compare_norm_strings(x, y)
          xi = 0
          yi = 0
          xi += 1 while blank_ch?(x.getbyte(xi) || 0)
          yi += 1 while blank_ch?(y.getbyte(yi) || 0)
          loop do
            xc = x.getbyte(xi) || 0
            yc = y.getbyte(yi) || 0
            break if xc == 0 || yc == 0

            if blank_ch?(xc)
              return xc - yc unless blank_ch?(yc)

              xi += 1 while blank_ch?(x.getbyte(xi) || 0)
              yi += 1 while blank_ch?(y.getbyte(yi) || 0)
            else
              tmp = xc - yc
              xi += 1
              yi += 1
              return -1 if tmp < 0
              return 1 if tmp > 0
            end
          end
          if (x.getbyte(xi) || 0) != 0
            xi += 1 while blank_ch?(x.getbyte(xi) || 0)
            return 1 if (x.getbyte(xi) || 0) != 0
          end
          if (y.getbyte(yi) || 0) != 0
            yi += 1 while blank_ch?(y.getbyte(yi) || 0)
            return -1 if (y.getbyte(yi) || 0) != 0
          end
          0
        end

        # xmlSchemaCompareFloats
        def compare_floats(x, y)
          return -2 if x.nil? || y.nil?

          # Cast everything to doubles.
          d1 = case x.type
          when XML_SCHEMAS_DOUBLE then x.d
          when XML_SCHEMAS_FLOAT then x.f
          else return -2
          end
          d2 = case y.type
          when XML_SCHEMAS_DOUBLE then y.d
          when XML_SCHEMAS_FLOAT then y.f
          else return -2
          end
          # Check for special cases.
          if d1.nan?
            return 0 if d2.nan?

            return 1
          end
          return -1 if d2.nan?

          if d1 == Float::INFINITY
            return 0 if d2 == Float::INFINITY

            return 1
          end
          return -1 if d2 == Float::INFINITY

          if d1 == -Float::INFINITY
            return 0 if d2 == -Float::INFINITY

            return -1
          end
          return 1 if d2 == -Float::INFINITY

          return -1 if d1 < d2
          return 1 if d1 > d2
          return 0 if d1 == d2

          2
        end

        # xmlSchemaCompareValuesInternal
        def compare_values_internal(xtype, x, xvalue, xws, ytype, y, yvalue, yws)
          case xtype
          when XML_SCHEMAS_UNKNOWN, XML_SCHEMAS_ANYTYPE
            -2
          when *DECIMAL_TYPES
            return -2 if x.nil? || y.nil?
            return compare_decimals(x, y) if ytype == xtype
            return compare_decimals(x, y) if DECIMAL_TYPES.include?(ytype)

            -2
          when XML_SCHEMAS_DURATION
            return -2 if x.nil? || y.nil?
            return compare_durations(x, y) if ytype == XML_SCHEMAS_DURATION

            -2
          when *DATE_TYPES
            return -2 if x.nil? || y.nil?
            return compare_dates(x, y) if DATE_TYPES.include?(ytype)

            -2
          # Note that we will support comparison of string types against anySimpleType as well.
          when *STRING_TYPES
            xv = x.nil? ? xvalue : x.str
            yv = y.nil? ? yvalue : y.str
            # TODO: Compare those against QName.
            return -2 if ytype == XML_SCHEMAS_QNAME

            if STRING_TYPES.include?(ytype)
              if xws == XML_SCHEMA_WHITESPACE_PRESERVE
                if yws == XML_SCHEMA_WHITESPACE_PRESERVE
                  # TODO: What about x < y or x > y.
                  return xv == yv ? 0 : 2
                elsif yws == XML_SCHEMA_WHITESPACE_REPLACE
                  return compare_preserve_replace_strings(xv, yv, false)
                elsif yws == XML_SCHEMA_WHITESPACE_COLLAPSE
                  return compare_preserve_collapse_strings(xv, yv, false)
                end
              elsif xws == XML_SCHEMA_WHITESPACE_REPLACE
                return compare_preserve_replace_strings(yv, xv, true) if yws == XML_SCHEMA_WHITESPACE_PRESERVE
                return compare_replaced_strings(xv, yv) if yws == XML_SCHEMA_WHITESPACE_REPLACE
                return compare_replace_collapse_strings(xv, yv, false) if yws == XML_SCHEMA_WHITESPACE_COLLAPSE
              elsif xws == XML_SCHEMA_WHITESPACE_COLLAPSE
                return compare_preserve_collapse_strings(yv, xv, true) if yws == XML_SCHEMA_WHITESPACE_PRESERVE
                return compare_replace_collapse_strings(yv, xv, true) if yws == XML_SCHEMA_WHITESPACE_REPLACE
                return compare_norm_strings(xv, yv) if yws == XML_SCHEMA_WHITESPACE_COLLAPSE
              else
                return -2
              end
            end
            -2
          when XML_SCHEMAS_QNAME, XML_SCHEMAS_NOTATION
            return -2 if x.nil? || y.nil?

            if ytype == XML_SCHEMAS_QNAME || ytype == XML_SCHEMAS_NOTATION
              return 0 if x.str == y.str && x.uri == y.uri

              return 2
            end
            -2
          when XML_SCHEMAS_FLOAT, XML_SCHEMAS_DOUBLE
            return -2 if x.nil? || y.nil?
            return compare_floats(x, y) if ytype == XML_SCHEMAS_FLOAT || ytype == XML_SCHEMAS_DOUBLE

            -2
          when XML_SCHEMAS_BOOLEAN
            return -2 if x.nil? || y.nil?

            if ytype == XML_SCHEMAS_BOOLEAN
              return 0 if x.b == y.b
              return -1 if x.b == 0

              return 1
            end
            -2
          when XML_SCHEMAS_HEXBINARY
            return -2 if x.nil? || y.nil?

            if ytype == XML_SCHEMAS_HEXBINARY
              if x.total == y.total
                ret = c_strcmp(x.str, y.str)
                return 1 if ret > 0
                return 0 if ret == 0
              elsif x.total > y.total
                return 1
              end
              return -1
            end
            -2
          when XML_SCHEMAS_BASE64BINARY
            return -2 if x.nil? || y.nil?

            if ytype == XML_SCHEMAS_BASE64BINARY
              if x.total == y.total
                ret = c_strcmp(x.str, y.str)
                return 1 if ret > 0
                return 0 if ret == 0

                return -1
              end
              return x.total > y.total ? 1 : -1
            end
            -2
          else
            # XML_SCHEMAS_IDREFS, XML_SCHEMAS_ENTITIES, XML_SCHEMAS_NMTOKENS: TODO in libxml2
            -2
          end
        end

        # xmlStrcmp (NULL sorts first)
        def c_strcmp(a, b)
          return 0 if a.equal?(b)
          return -1 if a.nil?
          return 1 if b.nil?

          a.b <=> b.b
        end
        private :c_strcmp

        def default_ws(val)
          case val.type
          when XML_SCHEMAS_STRING then XML_SCHEMA_WHITESPACE_PRESERVE
          when XML_SCHEMAS_NORMSTRING then XML_SCHEMA_WHITESPACE_REPLACE
          else XML_SCHEMA_WHITESPACE_COLLAPSE
          end
        end
        private :default_ws

        # xmlSchemaCompareValues
        def compare_values(x, y)
          return -2 if x.nil? || y.nil?

          compare_values_internal(x.type, x, nil, default_ws(x), y.type, y, nil, default_ws(y))
        end

        # xmlSchemaCompareValuesWhtsp
        def compare_values_whtsp(x, xws, y, yws)
          return -2 if x.nil? || y.nil?

          compare_values_internal(x.type, x, nil, xws, y.type, y, nil, yws)
        end

        # xmlSchemaCompareValuesWhtspExt
        def compare_values_whtsp_ext(xtype, x, xvalue, xws, ytype, y, yvalue, yws)
          compare_values_internal(xtype, x, xvalue, xws, ytype, y, yvalue, yws)
        end

        # xmlSchemaNormLen
        def norm_len(value)
          return -1 if value.nil?

          i = 0
          ret = 0
          i += 1 while blank_ch?(value.getbyte(i) || 0)
          while (c = value.getbyte(i) || 0) != 0
            if c & 0x80 != 0
              return -1 if ((value.getbyte(i + 1) || 0) & 0xc0) != 0x80

              if (c & 0xe0) == 0xe0
                return -1 if ((value.getbyte(i + 2) || 0) & 0xc0) != 0x80

                if (c & 0xf0) == 0xf0
                  return -1 if (c & 0xf8) != 0xf0 || ((value.getbyte(i + 3) || 0) & 0xc0) != 0x80

                  i += 4
                else
                  i += 3
                end
              else
                i += 2
              end
            elsif blank_ch?(c)
              i += 1 while blank_ch?(value.getbyte(i) || 0)
              break if (value.getbyte(i) || 0) == 0
            else
              i += 1
            end
            ret += 1
          end
          ret
        end

        # xmlSchemaGetFacetValueAsULong: strtoul(decimal.str + 1)
        def get_facet_value_as_u_long(facet)
          return 0 if facet.nil? || facet.val.nil? || facet.val.str.nil?

          digits = facet.val.str.byteslice(1..)[/\A[0-9]+/]
          return 0 if digits.nil?

          v = digits.to_i
          v > ULONG_MAX ? ULONG_MAX : v
        end

        # xmlSchemaValidateListSimpleTypeFacet. Returns [ret, expected_len] (expected_len nil
        # when C leaves *expectedLen untouched).
        def validate_list_simple_type_facet(facet, value, actual_len)
          return [-1, nil] if facet.nil?

          case facet.type
          when XML_SCHEMA_FACET_LENGTH
            if actual_len != get_facet_value_as_u_long(facet)
              return [ErrCode::SCHEMAV_CVC_LENGTH_VALID, get_facet_value_as_u_long(facet)]
            end
          when XML_SCHEMA_FACET_MINLENGTH
            if actual_len < get_facet_value_as_u_long(facet)
              return [ErrCode::SCHEMAV_CVC_MINLENGTH_VALID, get_facet_value_as_u_long(facet)]
            end
          when XML_SCHEMA_FACET_MAXLENGTH
            if actual_len > get_facet_value_as_u_long(facet)
              return [ErrCode::SCHEMAV_CVC_MAXLENGTH_VALID, get_facet_value_as_u_long(facet)]
            end
          else
            # NOTE: That we can pass NULL as xmlSchemaValPtr to xmlSchemaValidateFacet, since
            # the remaining facet types are: XML_SCHEMA_FACET_PATTERN, XML_SCHEMA_FACET_ENUMERATION.
            return [validate_facet(nil, facet, value, nil), nil]
          end
          [0, nil]
        end

        # the length computation shared by xmlSchemaValidateLengthFacetInternal and
        # xmlSchemaValidateFacetInternal (C unsigned int)
        def facet_value_length(val_type, value, val, ws)
          len = 0
          if !val.nil? && val.type == XML_SCHEMAS_HEXBINARY
            len = val.total
          elsif !val.nil? && val.type == XML_SCHEMAS_BASE64BINARY
            len = val.total
          else
            case val_type
            when XML_SCHEMAS_STRING, XML_SCHEMAS_NORMSTRING
              if ws == XML_SCHEMA_WHITESPACE_UNKNOWN
                # This is to ensure API compatibility with the old xmlSchemaValidateLengthFacet().
                len = val_type == XML_SCHEMAS_STRING ? utf8_strlen(value) : norm_len(value)
              elsif !value.nil?
                len = ws == XML_SCHEMA_WHITESPACE_COLLAPSE ? norm_len(value) : utf8_strlen(value)
              end
            when XML_SCHEMAS_IDREF, XML_SCHEMAS_TOKEN, XML_SCHEMAS_LANGUAGE, XML_SCHEMAS_NMTOKEN,
              XML_SCHEMAS_NAME, XML_SCHEMAS_NCNAME, XML_SCHEMAS_ID, XML_SCHEMAS_ANYURI
              len = norm_len(value) unless value.nil?
            end
          end
          len & 0xFFFFFFFF
        end
        private :facet_value_length

        # xmlSchemaValidateLengthFacetInternal. Returns [ret, length].
        def validate_length_facet_internal(facet, val_type, value, val, ws)
          return [-1, nil] if facet.nil?

          length = 0
          ft = facet.type
          if ft != XML_SCHEMA_FACET_LENGTH && ft != XML_SCHEMA_FACET_MAXLENGTH && ft != XML_SCHEMA_FACET_MINLENGTH
            return [-1, length]
          end
          fv = facet.val
          if fv.nil? || (fv.type != XML_SCHEMAS_DECIMAL && fv.type != XML_SCHEMAS_NNINTEGER) ||
              !val_decimal_is_integer(fv)
            return [-1, length]
          end
          if (val.nil? || (val.type != XML_SCHEMAS_HEXBINARY && val.type != XML_SCHEMAS_BASE64BINARY)) &&
              (val_type == XML_SCHEMAS_QNAME || val_type == XML_SCHEMAS_NOTATION)
            # For QName and NOTATION, those facets are deprecated and should be ignored.
            return [0, length]
          end
          len = facet_value_length(val_type, value, val, ws)
          length = len
          if ft == XML_SCHEMA_FACET_LENGTH
            return [ErrCode::SCHEMAV_CVC_LENGTH_VALID, length] if len != get_facet_value_as_u_long(facet)
          elsif ft == XML_SCHEMA_FACET_MINLENGTH
            return [ErrCode::SCHEMAV_CVC_MINLENGTH_VALID, length] if len < get_facet_value_as_u_long(facet)
          elsif len > get_facet_value_as_u_long(facet)
            return [ErrCode::SCHEMAV_CVC_MAXLENGTH_VALID, length]
          end
          [0, length]
        end

        # xmlSchemaValidateLengthFacet. Returns [ret, length].
        def validate_length_facet(type, facet, value, val)
          return [-1, nil] if type.nil?

          validate_length_facet_internal(facet, type.built_in_type, value, val, XML_SCHEMA_WHITESPACE_UNKNOWN)
        end

        # xmlSchemaValidateLengthFacetWhtsp. Returns [ret, length].
        def validate_length_facet_whtsp(facet, val_type, value, val, ws)
          validate_length_facet_internal(facet, val_type, value, val, ws)
        end

        # xmlSchemaValidateFacetInternal
        def validate_facet_internal(facet, fws, val_type, value, val, ws)
          return -1 if facet.nil?

          case facet.type
          when XML_SCHEMA_FACET_PATTERN
            # NOTE that for patterns, the @value needs to be the normalized value, *not* the
            # lexical initial value or the canonical value.
            return -1 if value.nil?

            # If string-derived type, regexp must be tested on the value space of the datatype.
            if !val.nil? && !val.str.nil? &&
                ((val.type >= XML_SCHEMAS_STRING && val.type <= XML_SCHEMAS_NORMSTRING) ||
                 (val.type >= XML_SCHEMAS_TOKEN && val.type <= XML_SCHEMAS_ENTITIES &&
                  val.type != XML_SCHEMAS_QNAME))
              value = val.str
            end
            ret = XmlRegexp.regexp_exec(facet.regexp, value)
            return 0 if ret == 1
            return ErrCode::SCHEMAV_CVC_PATTERN_VALID if ret == 0

            ret
          when XML_SCHEMA_FACET_MAXEXCLUSIVE
            ret = compare_values(val, facet.val)
            return -1 if ret == -2
            return 0 if ret == -1

            ErrCode::SCHEMAV_CVC_MAXEXCLUSIVE_VALID
          when XML_SCHEMA_FACET_MAXINCLUSIVE
            ret = compare_values(val, facet.val)
            return -1 if ret == -2
            return 0 if ret == -1 || ret == 0

            ErrCode::SCHEMAV_CVC_MAXINCLUSIVE_VALID
          when XML_SCHEMA_FACET_MINEXCLUSIVE
            ret = compare_values(val, facet.val)
            return -1 if ret == -2
            return 0 if ret == 1

            ErrCode::SCHEMAV_CVC_MINEXCLUSIVE_VALID
          when XML_SCHEMA_FACET_MININCLUSIVE
            ret = compare_values(val, facet.val)
            return -1 if ret == -2
            return 0 if ret == 1 || ret == 0

            ErrCode::SCHEMAV_CVC_MININCLUSIVE_VALID
          when XML_SCHEMA_FACET_WHITESPACE
            # TODO whitespaces
            0
          when XML_SCHEMA_FACET_ENUMERATION
            if ws == XML_SCHEMA_WHITESPACE_UNKNOWN
              # This is to ensure API compatibility with the old xmlSchemaValidateFacet().
              return 0 if !facet.value.nil? && facet.value == value
            else
              ftype = facet.val.nil? ? XML_SCHEMAS_UNKNOWN : facet.val.type
              ret = compare_values_whtsp_ext(ftype, facet.val, facet.value, fws, val_type, val, value, ws)
              return -1 if ret == -2
              return 0 if ret == 0
            end
            ErrCode::SCHEMAV_CVC_ENUMERATION_VALID
          when XML_SCHEMA_FACET_LENGTH, XML_SCHEMA_FACET_MAXLENGTH, XML_SCHEMA_FACET_MINLENGTH
            # SPEC (1.3) "if {primitive type definition} is QName or NOTATION, then any {value}
            # is facet-valid."
            return 0 if val_type == XML_SCHEMAS_QNAME || val_type == XML_SCHEMAS_NOTATION

            fv = facet.val
            if fv.nil? || (fv.type != XML_SCHEMAS_DECIMAL && fv.type != XML_SCHEMAS_NNINTEGER) ||
                !val_decimal_is_integer(fv)
              return -1
            end
            len = facet_value_length(val_type, value, val, ws)
            if facet.type == XML_SCHEMA_FACET_LENGTH
              return ErrCode::SCHEMAV_CVC_LENGTH_VALID if len != get_facet_value_as_u_long(facet)
            elsif facet.type == XML_SCHEMA_FACET_MINLENGTH
              return ErrCode::SCHEMAV_CVC_MINLENGTH_VALID if len < get_facet_value_as_u_long(facet)
            elsif len > get_facet_value_as_u_long(facet)
              return ErrCode::SCHEMAV_CVC_MAXLENGTH_VALID
            end
            0
          when XML_SCHEMA_FACET_TOTALDIGITS, XML_SCHEMA_FACET_FRACTIONDIGITS
            fv = facet.val
            if fv.nil? || (fv.type != XML_SCHEMAS_PINTEGER && fv.type != XML_SCHEMAS_NNINTEGER) ||
                !val_decimal_is_integer(fv)
              return -1
            end
            return -1 if val.nil? || !DECIMAL_TYPES.include?(val.type)

            if facet.type == XML_SCHEMA_FACET_TOTALDIGITS
              if val_decimal_get_significant_digit_count(val) > get_facet_value_as_u_long(facet)
                return ErrCode::SCHEMAV_CVC_TOTALDIGITS_VALID
              end
            else
              frac = val_decimal_is_integer(val) ? 0 : val.fractional_places
              return ErrCode::SCHEMAV_CVC_FRACTIONDIGITS_VALID if frac > get_facet_value_as_u_long(facet)
            end
            0
          else
            # TODO
            0
          end
        end

        # xmlSchemaValidateFacet
        def validate_facet(base, facet, value, val)
          # This tries to ensure API compatibility regarding the old xmlSchemaValidateFacet() and
          # the new xmlSchemaValidateFacetInternal() and xmlSchemaValidateFacetWhtsp().
          if !val.nil?
            validate_facet_internal(facet, XML_SCHEMA_WHITESPACE_UNKNOWN, val.type, value, val,
              XML_SCHEMA_WHITESPACE_UNKNOWN)
          elsif !base.nil?
            validate_facet_internal(facet, XML_SCHEMA_WHITESPACE_UNKNOWN, base.built_in_type, value, val,
              XML_SCHEMA_WHITESPACE_UNKNOWN)
          else
            -1
          end
        end

        # xmlSchemaValidateFacetWhtsp
        def validate_facet_whtsp(facet, fws, val_type, value, val, ws)
          validate_facet_internal(facet, fws, val_type, value, val, ws)
        end

        # snprintf(buf, size, ...) truncation
        def c_snprintf(size, fmt, *args)
          s = format(fmt, *args)
          s.bytesize >= size ? s.byteslice(0, size - 1) : s
        end
        private :c_snprintf

        # printf("%.14g"/"%02.14g") of a double, with glibc's spelling of the special values
        def c_fmt_g(fmt, d)
          return d.nan? ? "nan" : (d > 0 ? "inf" : "-inf") unless d.finite?

          format(fmt, d)
        end
        private :c_fmt_g

        # printf("%01.14e") with glibc's spelling of the special values
        def c_fmt_e(d)
          return "nan" if d.nan?
          return d > 0 ? "inf" : "-inf" if d.infinite?

          format("%01.14e", d)
        end
        private :c_fmt_e

        # xmlSchemaGetCanonValue. Returns [ret, string].
        def get_canon_value(val)
          return [-1, nil] if val.nil?

          ret_value = nil
          case val.type
          when XML_SCHEMAS_STRING
            ret_value = val.str.nil? ? +"" : val.str.dup
          when XML_SCHEMAS_NORMSTRING
            if val.str.nil?
              ret_value = +""
            else
              ret_value = white_space_replace(val.str)
              ret_value = val.str.dup if ret_value.nil?
            end
          when XML_SCHEMAS_TOKEN, XML_SCHEMAS_LANGUAGE, XML_SCHEMAS_NMTOKEN, XML_SCHEMAS_NAME,
            XML_SCHEMAS_NCNAME, XML_SCHEMAS_ID, XML_SCHEMAS_IDREF, XML_SCHEMAS_ENTITY,
            XML_SCHEMAS_NOTATION, XML_SCHEMAS_ANYURI # NOTATION, ANYURI: Unclear
            return [-1, nil] if val.str.nil?

            ret_value = collapse_string(val.str)
            ret_value = val.str.dup if ret_value.nil?
          when XML_SCHEMAS_QNAME
            # TODO: Unclear in XML Schema 1.0.
            return [0, val.str.nil? ? nil : val.str.dup] if val.uri.nil?

            ret_value = +"{#{val.uri}}#{val.uri}"
          when XML_SCHEMAS_DECIMAL
            s = val.str
            ret_value = s.getbyte(0) == 0x2B ? s.byteslice(1..) : s.dup
          when XML_SCHEMAS_INTEGER, XML_SCHEMAS_PINTEGER, XML_SCHEMAS_NPINTEGER, XML_SCHEMAS_NINTEGER,
            XML_SCHEMAS_NNINTEGER, XML_SCHEMAS_LONG, XML_SCHEMAS_BYTE, XML_SCHEMAS_SHORT,
            XML_SCHEMAS_INT, XML_SCHEMAS_UINT, XML_SCHEMAS_ULONG, XML_SCHEMAS_USHORT, XML_SCHEMAS_UBYTE
            s = val.str
            # 2 = sign+NULL
            buf_size = val.integral_places + 2
            start = 0
            if s.getbyte(0) == 0x2B
              start = 1
              buf_size -= 1
            end
            ret_value = s.byteslice(start, buf_size - 1)
          when XML_SCHEMAS_BOOLEAN
            ret_value = val.b != 0 ? +"true" : +"false"
          when XML_SCHEMAS_DURATION
            # TODO: This results in a normalized output of the value - which is NOT conformant
            # to the spec - since the exact values of each property are not recoverable.
            year = fquotient(val.mon.abs, 12)
            mon = val.mon.abs - 12 * year
            day = (val.sec.abs / 86400).floor
            left = val.sec.abs - day * 86400
            hour = 0
            min = 0
            sec = 0.0
            if left > 0
              hour = (left / 3600).floor
              left -= hour * 3600
              if left > 0
                min = (left / 60).floor
                sec = left - min * 60
              end
            end
            sign = val.mon < 0 || val.sec < 0 ? "" : "-"
            ret_value = c_snprintf(100, "%sP%dY%dM%dDT%dH%dM%sS", sign, year, mon, day, hour, min,
              c_fmt_g("%.14g", sec))
          when XML_SCHEMAS_GYEAR
            # TODO: Unclear in XML Schema 1.0. TODO: What to do with the timezone?
            ret_value = c_snprintf(30, "%04d", val.year)
          when XML_SCHEMAS_GMONTH
            ret_value = c_snprintf(6, "--%02d", val.mon)
          when XML_SCHEMAS_GDAY
            ret_value = c_snprintf(6, "---%02d", val.day)
          when XML_SCHEMAS_GMONTHDAY
            ret_value = c_snprintf(8, "--%02d-%02d", val.mon, val.day)
          when XML_SCHEMAS_GYEARMONTH
            ret_value = if val.year < 0
              c_snprintf(35, "-%04d-%02d", val.year.abs, val.mon)
            else
              c_snprintf(35, "%04d-%02d", val.year, val.mon)
            end
          when XML_SCHEMAS_TIME
            if val.tz_flag != 0
              norm = date_normalize(val, 0)
              return [-1, nil] if norm.nil?

              ret_value = c_snprintf(30, "%02d:%02d:%sZ", norm.hour, norm.min, c_fmt_g("%02.14g", norm.sec))
            else
              ret_value = c_snprintf(30, "%02d:%02d:%s", val.hour, val.min, c_fmt_g("%02.14g", val.sec))
            end
          when XML_SCHEMAS_DATE
            if val.tz_flag != 0
              norm = date_normalize(val, 0)
              return [-1, nil] if norm.nil?

              # TODO: Append the canonical value of the recoverable timezone and not "Z".
              ret_value = c_snprintf(30, "%04d-%02d-%02dZ", norm.year, norm.mon, norm.day)
            else
              ret_value = c_snprintf(30, "%04d-%02d-%02d", val.year, val.mon, val.day)
            end
          when XML_SCHEMAS_DATETIME
            if val.tz_flag != 0
              norm = date_normalize(val, 0)
              return [-1, nil] if norm.nil?

              ret_value = c_snprintf(50, "%04d-%02d-%02dT%02d:%02d:%sZ", norm.year, norm.mon, norm.day,
                norm.hour, norm.min, c_fmt_g("%02.14g", norm.sec))
            else
              ret_value = c_snprintf(50, "%04d-%02d-%02dT%02d:%02d:%s", val.year, val.mon, val.day,
                val.hour, val.min, c_fmt_g("%02.14g", val.sec))
            end
          when XML_SCHEMAS_HEXBINARY, XML_SCHEMAS_BASE64BINARY
            ret_value = val.str&.dup
          when XML_SCHEMAS_FLOAT
            # TODO: Handle, NaN, INF, -INF. The format is not yet conformant.
            ret_value = c_snprintf(30, "%s", c_fmt_e(val.f))
          when XML_SCHEMAS_DOUBLE
            ret_value = c_snprintf(40, "%s", c_fmt_e(val.d))
          else
            return [1, +"???"]
          end
          return [-1, nil] if ret_value.nil?

          [0, ret_value]
        end

        # xmlSchemaGetCanonValueWhtsp. Returns [ret, string].
        def get_canon_value_whtsp(val, ws)
          return [-1, nil] if val.nil?
          return [-1, nil] if ws == XML_SCHEMA_WHITESPACE_UNKNOWN || ws > XML_SCHEMA_WHITESPACE_COLLAPSE

          ret_value = nil
          case val.type
          when XML_SCHEMAS_STRING
            if val.str.nil?
              ret_value = +""
            elsif ws == XML_SCHEMA_WHITESPACE_COLLAPSE
              ret_value = collapse_string(val.str)
            elsif ws == XML_SCHEMA_WHITESPACE_REPLACE
              ret_value = white_space_replace(val.str)
            end
            ret_value = val.str.dup if ret_value.nil?
          when XML_SCHEMAS_NORMSTRING
            if val.str.nil?
              ret_value = +""
            else
              ret_value = if ws == XML_SCHEMA_WHITESPACE_COLLAPSE
                collapse_string(val.str)
              else
                white_space_replace(val.str)
              end
              ret_value = val.str.dup if ret_value.nil?
            end
          else
            return get_canon_value(val)
          end
          [0, ret_value]
        end

        # xmlSchemaGetValType
        def get_val_type(val)
          return XML_SCHEMAS_UNKNOWN if val.nil?

          val.type
        end
      end
    end
  end
end
