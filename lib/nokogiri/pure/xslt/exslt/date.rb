# frozen_string_literal: true

# Port of libexslt/date.c: the EXSLT Dates and Times module (date:date-time, date:date,
# date:time, date:year, ..., date:add, date:add-duration, date:difference, date:duration,
# date:seconds, date:sum).
#
# Parsing and formatting work on the bytes of the string exactly like the C code. C integer
# arithmetic (truncating division/remainder, LONG_MAX overflow checks) is reproduced with
# cdiv/cmod and explicit range checks; the bit-field members of exsltDateVal never receive
# out-of-range values in the C code, so plain Integers are used for them.

module Nokogiri
  module Pure
    module XSLT
      module EXSLT
        # exsltDateType
        EXSLT_UNKNOWN = 0
        XS_TIME = 1
        XS_GDAY = XS_TIME << 1
        XS_GMONTH = XS_GDAY << 1
        XS_GMONTHDAY = XS_GMONTH | XS_GDAY
        XS_GYEAR = XS_GMONTH << 1
        XS_GYEARMONTH = XS_GYEAR | XS_GMONTH
        XS_DATE = XS_GYEAR | XS_GMONTH | XS_GDAY
        XS_DATETIME = XS_DATE | XS_TIME

        # exsltDateVal
        class DateVal
          attr_accessor :type, :year, :mon, :day, :hour, :min, :sec, :tz_flag, :tzo

          # exsltDateCreateDate
          def initialize(type = EXSLT_UNKNOWN)
            @type = type
            @year = 0
            @mon = 1
            @day = 1
            @hour = 0
            @min = 0
            @sec = 0.0
            @tz_flag = 0
            @tzo = 0
          end
        end

        # exsltDateDurVal
        class DateDurVal
          attr_accessor :mon, :day, :sec

          # exsltDateCreateDuration
          def initialize
            @mon = 0
            @day = 0
            @sec = 0.0
          end
        end

        DAYS_IN_MONTH = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31].freeze
        DAYS_IN_MONTH_LEAP = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31].freeze
        DAY_IN_YEAR_BY_MONTH = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334].freeze
        DAY_IN_LEAP_YEAR_BY_MONTH = [0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335].freeze

        SECS_PER_MIN = 60
        MINS_PER_HOUR = 60
        HOURS_PER_DAY = 24
        SECS_PER_HOUR = MINS_PER_HOUR * SECS_PER_MIN
        SECS_PER_DAY = HOURS_PER_DAY * SECS_PER_HOUR
        MINS_PER_DAY = HOURS_PER_DAY * MINS_PER_HOUR
        DAYS_PER_EPOCH = (400 * 365) + 100 - 4 + 1
        YEARS_PER_EPOCH = 400

        YEAR_MAX = LONG_MAX
        YEAR_MIN = -LONG_MAX + 1

        MONTH_NAMES = ["", "January", "February", "March", "April", "May", "June", "July",
                       "August", "September", "October", "November", "December"].freeze
        MONTH_ABBREVIATIONS = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep",
                               "Oct", "Nov", "Dec"].freeze
        DAY_NAMES = ["", "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday",
                     "Saturday"].freeze
        DAY_ABBREVIATIONS = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].freeze

        # the size of the formatting buffers (xmlChar buf[100], end = buf + 99)
        DATE_BUF_MAX = 99

        module_function

        # ---- convenience macros ------------------------------------------------------------

        def tzo_char?(c) = c == 0 || c == 0x5A || c == 0x2B || c == 0x2D # 0 'Z' '+' '-'
        def digit?(c) = c >= 0x30 && c <= 0x39
        def valid_month?(mon) = mon >= 1 && mon <= 12
        def valid_day?(day) = day >= 1 && day <= 31
        def valid_hour?(hr) = hr >= 0 && hr <= 23
        def valid_min?(min) = min >= 0 && min <= 59
        def valid_sec?(sec) = sec >= 0 && sec < 60
        def valid_tzo?(tzo) = tzo > -1440 && tzo < 1440

        # IS_LEAP
        def leap?(y)
          (y & 3) == 0 && (y % 25 != 0 || (y & 15) == 0)
        end

        # MAX_DAYINMONTH
        def max_day_in_month(yr, mon)
          leap?(yr) ? DAYS_IN_MONTH_LEAP[mon - 1] : DAYS_IN_MONTH[mon - 1]
        end

        # VALID_MDAY
        def valid_mday?(dt)
          dt.day <= max_day_in_month(dt.year, dt.mon)
        end

        # VALID_DATE
        def valid_date?(dt)
          valid_month?(dt.mon) && valid_mday?(dt)
        end

        # VALID_TIME
        def valid_time?(dt)
          dt.hour <= 23 && dt.min <= 59 && valid_sec?(dt.sec) && valid_tzo?(dt.tzo)
        end

        # VALID_DATETIME
        def valid_datetime?(dt)
          valid_date?(dt) && valid_time?(dt)
        end

        # DAY_IN_YEAR
        def day_in_year(day, month, year)
          (leap?(year) ? DAY_IN_LEAP_YEAR_BY_MONTH[month - 1] : DAY_IN_YEAR_BY_MONTH[month - 1]) + day
        end

        # ---- parsing -----------------------------------------------------------------------
        #
        # The _exsltDateParse* functions take the (binary) string and a position and return
        # [error_code, new_position]; the position only advances on success.

        # PARSE_2_DIGITS: the value of the two digits at +cur+, or nil if they aren't digits
        def date_two_digits(s, cur)
          c0 = byte_at(s, cur)
          return nil unless digit?(c0)

          c1 = byte_at(s, cur + 1)
          return nil unless digit?(c1)

          ((c0 - 0x30) * 10) + (c1 - 0x30)
        end

        # _exsltDateParseGYear
        def date_parse_gyear(dt, s, pos)
          cur = pos
          c = byte_at(s, cur)
          return [-1, pos] if !digit?(c) && c != 0x2D && c != 0x2B

          isneg = false
          if c == 0x2D
            isneg = true
            cur += 1
          end

          first_char = byte_at(s, cur)
          digcnt = 0
          while digit?(c = byte_at(s, cur))
            return [-1, pos] if dt.year >= YEAR_MAX / 10 # Not really exact

            dt.year = (dt.year * 10) + (c - 0x30)
            cur += 1
            digcnt += 1
          end

          # year must be at least 4 digits (CCYY); over 4 digits cannot have a leading zero.
          return [1, pos] if digcnt < 4 || (digcnt > 4 && first_char == 0x30)
          return [2, pos] if dt.year == 0

          # The internal representation of negative years is continuous.
          dt.year = -dt.year + 1 if isneg

          [0, cur]
        end

        # _exsltDateParseGMonth
        def date_parse_gmonth(dt, s, pos)
          val = date_two_digits(s, pos)
          return [1, pos] if val.nil?
          return [2, pos] unless valid_month?(val)

          dt.mon = val
          [0, pos + 2]
        end

        # _exsltDateParseGDay
        def date_parse_gday(dt, s, pos)
          val = date_two_digits(s, pos)
          return [1, pos] if val.nil?
          return [2, pos] unless valid_day?(val)

          dt.day = val
          [0, pos + 2]
        end

        # _exsltDateParseTime
        def date_parse_time(dt, s, pos)
          cur = pos
          hour = date_two_digits(s, cur)
          return [1, pos] if hour.nil?
          return [2, pos] unless valid_hour?(hour)

          cur += 2
          return [1, pos] if byte_at(s, cur) != 0x3A # ':'

          cur += 1

          # the ':' insures this string is xs:time
          dt.hour = hour

          val = date_two_digits(s, cur)
          return [1, pos] if val.nil?
          return [2, pos] unless valid_min?(val)

          dt.min = val
          cur += 2
          return [1, pos] if byte_at(s, cur) != 0x3A

          cur += 1

          # PARSE_FLOAT
          val = date_two_digits(s, cur)
          return [1, pos] if val.nil?

          dt.sec = val.to_f
          cur += 2
          if byte_at(s, cur) == 0x2E # '.'
            mult = 1.0
            cur += 1
            invalid = !digit?(byte_at(s, cur))
            while digit?(c = byte_at(s, cur))
              mult /= 10
              dt.sec += (c - 0x30) * mult
              cur += 1
            end
            return [1, pos] if invalid
          end

          return [2, pos] unless valid_time?(dt)

          [0, cur]
        end

        # _exsltDateParseTimeZone
        def date_parse_time_zone(dt, s, pos)
          cur = pos
          case byte_at(s, cur)
          when 0
            dt.tz_flag = 0
            dt.tzo = 0
          when 0x5A # 'Z'
            dt.tz_flag = 1
            dt.tzo = 0
            cur += 1
          when 0x2B, 0x2D # '+', '-'
            isneg = byte_at(s, cur) == 0x2D
            cur += 1

            tmp = date_two_digits(s, cur)
            return [1, pos] if tmp.nil?
            return [2, pos] unless valid_hour?(tmp)

            cur += 2
            return [1, pos] if byte_at(s, cur) != 0x3A

            cur += 1
            dt.tzo = tmp * 60

            tmp = date_two_digits(s, cur)
            return [1, pos] if tmp.nil?
            return [2, pos] unless valid_min?(tmp)

            cur += 2
            dt.tzo += tmp
            dt.tzo = -dt.tzo if isneg

            return [2, pos] unless valid_tzo?(dt.tzo)
          else
            return [1, pos]
          end
          [0, cur]
        end

        # exsltDateParse: a DateVal, or nil
        def date_parse(date_time)
          return nil if date_time.nil?

          s = date_time.b
          cur = 0
          dt = DateVal.new(EXSLT_UNKNOWN)

          # RETURN_TYPE_IF_VALID: :ok (dt->type set), :error, or nil to go on
          return_type_if_valid = lambda do |t|
            next nil unless tzo_char?(byte_at(s, cur))

            ret, ncur = date_parse_time_zone(dt, s, cur)
            next nil if ret != 0

            cur = ncur
            next :error if byte_at(s, cur) != 0

            dt.type = t
            :ok
          end

          if byte_at(s, 0) == 0x2D && byte_at(s, 1) == 0x2D
            # It's an incomplete date (xs:gMonthDay, xs:gMonth or xs:gDay)
            cur += 2

            # is it an xs:gDay?
            if byte_at(s, cur) == 0x2D
              cur += 1
              ret, cur = date_parse_gday(dt, s, cur)
              return nil if ret != 0

              return return_type_if_valid.call(XS_GDAY) == :ok ? dt : nil
            end

            # it should be an xs:gMonthDay or xs:gMonth
            ret, cur = date_parse_gmonth(dt, s, cur)
            return nil if ret != 0
            return nil if byte_at(s, cur) != 0x2D

            cur += 1

            # is it an xs:gMonth?
            if byte_at(s, cur) == 0x2D
              cur += 1
              return return_type_if_valid.call(XS_GMONTH) == :ok ? dt : nil
            end

            # it should be an xs:gMonthDay
            ret, cur = date_parse_gday(dt, s, cur)
            return nil if ret != 0

            return return_type_if_valid.call(XS_GMONTHDAY) == :ok ? dt : nil
          end

          # It's a right-truncated date or an xs:time.
          # Try to parse an xs:time then fallback on right-truncated dates.
          if digit?(byte_at(s, cur))
            ret, ncur = date_parse_time(dt, s, cur)
            if ret == 0
              cur = ncur
              # it's an xs:time
              r = return_type_if_valid.call(XS_TIME)
              return dt if r == :ok
              return nil if r == :error
            end
          end

          # fallback on date parsing
          cur = 0

          ret, cur = date_parse_gyear(dt, s, cur)
          return nil if ret != 0

          # is it an xs:gYear?
          r = return_type_if_valid.call(XS_GYEAR)
          return dt if r == :ok
          return nil if r == :error
          return nil if byte_at(s, cur) != 0x2D

          cur += 1

          ret, cur = date_parse_gmonth(dt, s, cur)
          return nil if ret != 0

          # is it an xs:gYearMonth?
          r = return_type_if_valid.call(XS_GYEARMONTH)
          return dt if r == :ok
          return nil if r == :error
          return nil if byte_at(s, cur) != 0x2D

          cur += 1

          ret, cur = date_parse_gday(dt, s, cur)
          return nil if ret != 0 || !valid_date?(dt)

          # is it an xs:date?
          r = return_type_if_valid.call(XS_DATE)
          return dt if r == :ok
          return nil if r == :error
          return nil if byte_at(s, cur) != 0x54 # 'T'

          cur += 1

          # it should be an xs:dateTime
          ret, cur = date_parse_time(dt, s, cur)
          return nil if ret != 0

          ret, cur = date_parse_time_zone(dt, s, cur)
          return nil if ret != 0 || byte_at(s, cur) != 0 || !valid_datetime?(dt)

          dt.type = XS_DATETIME
          dt
        end

        DURATION_DESIG = [0x59, 0x4D, 0x44, 0x48, 0x4D, 0x53].freeze # Y M D H M S

        # exsltDateParseDuration: a DateDurVal, or nil
        def date_parse_duration(duration)
          return nil if duration.nil?

          s = duration.b
          cur = 0
          isneg = false
          seq = 0
          secs = 0
          sec_frac = 0.0

          if byte_at(s, cur) == 0x2D
            isneg = true
            cur += 1
          end

          # duration must start with 'P' (after sign)
          return nil if byte_at(s, cur) != 0x50

          cur += 1
          return nil if byte_at(s, cur) == 0

          dur = DateDurVal.new

          while byte_at(s, cur) != 0
            num = 0
            has_digits = false
            has_frac = false

            # input string should be empty or invalid date/time item
            return nil if seq >= DURATION_DESIG.length

            # T designator must be present for time items
            if byte_at(s, cur) == 0x54 # 'T'
              return nil if seq > 3

              cur += 1
              seq = 3
            elsif seq == 3
              return nil
            end

            # Parse integral part.
            while digit?(c = byte_at(s, cur))
              digit = c - 0x30
              return nil if num > LONG_MAX / 10

              num *= 10
              return nil if num > LONG_MAX - digit

              num += digit
              has_digits = true
              cur += 1
            end

            if byte_at(s, cur) == 0x2E # '.'
              # Parse fractional part.
              mult = 1.0
              cur += 1
              has_frac = true
              while digit?(c = byte_at(s, cur))
                mult /= 10.0
                sec_frac += (c - 0x30) * mult
                has_digits = true
                cur += 1
              end
            end

            while byte_at(s, cur) != DURATION_DESIG[seq]
              seq += 1
              # No T designator or invalid char.
              return nil if seq == 3 || seq == DURATION_DESIG.length
            end
            cur += 1

            return nil if !has_digits || (has_frac && seq != 5)

            case seq
            when 0 # Year
              return nil if num > LONG_MAX / 12

              dur.mon = num * 12
            when 1 # Month
              return nil if dur.mon > LONG_MAX - num

              dur.mon += num
            when 2 # Day
              dur.day = num
            when 3 # Hour
              days = num / HOURS_PER_DAY
              return nil if dur.day > LONG_MAX - days

              dur.day += days
              secs = (num % HOURS_PER_DAY) * SECS_PER_HOUR
            when 4 # Minute
              days = num / MINS_PER_DAY
              return nil if dur.day > LONG_MAX - days

              dur.day += days
              secs += (num % MINS_PER_DAY) * SECS_PER_MIN
            when 5 # Second
              days = num / SECS_PER_DAY
              return nil if dur.day > LONG_MAX - days

              dur.day += days
              secs += num % SECS_PER_DAY
            end

            seq += 1
          end

          days = secs / SECS_PER_DAY
          return nil if dur.day > LONG_MAX - days

          dur.day += days
          dur.sec = (secs % SECS_PER_DAY) + sec_frac

          if isneg
            dur.mon = -dur.mon
            dur.day = -dur.day
            if dur.sec != 0.0
              dur.sec = SECS_PER_DAY - dur.sec
              dur.day -= 1
            end
          end

          dur
        end

        # ---- formatting --------------------------------------------------------------------
        #
        # The exsltFormat* helpers append to a binary String buffer that never grows beyond
        # DATE_BUF_MAX bytes (like the `if (*cur < end)` checks of the C code).

        def date_put(buf, ch)
          buf << ch if buf.bytesize < DATE_BUF_MAX
        end

        # exsltFormatGYear
        def date_format_gyear(buf, yr)
          date_put(buf, 0x2D) if yr <= 0

          year = yr <= 0 ? -yr + 1 : yr
          tmp = []
          # result is in reverse-order
          while year > 0 && tmp.length < 99
            tmp << (0x30 + (year % 10))
            year /= 10
          end
          # virtually adds leading zeros
          tmp << 0x30 while tmp.length < 4
          # restore the correct order
          tmp.reverse_each { |c| date_put(buf, c) }
        end

        # exsltFormat2Digits
        def date_format_2digits(buf, num)
          date_put(buf, 0x30 + ((num / 10) % 10))
          date_put(buf, 0x30 + (num % 10))
        end

        # exsltFormatYearMonthDay
        def date_format_year_month_day(buf, dt)
          date_format_gyear(buf, dt.year)
          date_put(buf, 0x2D)
          date_format_2digits(buf, dt.mon)
          date_put(buf, 0x2D)
          date_format_2digits(buf, dt.day)
        end

        # exsltFormatTimeZone
        def date_format_time_zone(buf, tzo)
          if tzo == 0
            date_put(buf, 0x5A)
          else
            a_tzo = tzo.abs
            date_put(buf, tzo < 0 ? 0x2D : 0x2B)
            date_format_2digits(buf, a_tzo / 60)
            date_put(buf, 0x3A)
            date_format_2digits(buf, a_tzo % 60)
          end
        end

        # exsltFormatLong
        def date_format_long(buf, num)
          digits = []
          while digits.length < 20
            digits << ((0x30 + cmod(num, 10)) & 0xFF)
            num = cdiv(num, 10)
            break if num == 0
          end
          digits.reverse_each { |c| date_put(buf, c) }
        end

        # exsltFormatNanoseconds
        def date_format_nanoseconds(buf, nsecs)
          return unless nsecs > 0

          date_put(buf, 0x2E)
          p10 = 100_000_000
          while nsecs > 0
            digit = nsecs / p10
            date_put(buf, 0x30 + digit)
            nsecs -= digit * p10
            p10 /= 10
          end
        end

        # exsltDateFormatDuration: a String, or nil
        def date_format_duration(dur)
          return nil if dur.nil?

          # quick and dirty check
          return +"P0D" if dur.sec == 0.0 && dur.day == 0 && dur.mon == 0

          secs = dur.sec
          days = dur.day
          months = dur.mon

          buf = +"".b
          neg = false
          if days < 0
            if secs != 0.0
              secs = SECS_PER_DAY - secs
              days += 1
            end
            days = -days
            neg = true
          end
          if months < 0
            months = -months
            neg = true
          end
          buf << "-" if neg
          buf << "P"

          if months >= 12
            years = cdiv(months, 12)
            months -= years * 12
            date_format_long(buf, years)
            date_put(buf, 0x59) # 'Y'
          end

          if months != 0
            date_format_long(buf, months)
            date_put(buf, 0x4D) # 'M'
          end

          if days != 0
            date_format_long(buf, days)
            date_put(buf, 0x44) # 'D'
          end

          tmp = secs.floor.to_f
          int_secs = tmp.to_i
          # Round to nearest to avoid issues with floating point precision
          nsecs = (((secs - tmp) * 1_000_000_000) + 0.5).floor
          if nsecs >= 1_000_000_000
            nsecs -= 1_000_000_000
            int_secs += 1
          end

          if int_secs > 0 || nsecs > 0
            date_put(buf, 0x54) # 'T'

            if int_secs >= SECS_PER_HOUR
              hours = int_secs / SECS_PER_HOUR
              int_secs -= hours * SECS_PER_HOUR
              date_format_long(buf, hours)
              date_put(buf, 0x48) # 'H'
            end

            if int_secs >= SECS_PER_MIN
              mins = int_secs / SECS_PER_MIN
              int_secs -= mins * SECS_PER_MIN
              date_format_long(buf, mins)
              date_put(buf, 0x4D) # 'M'
            end

            if int_secs > 0 || nsecs > 0
              date_format_long(buf, int_secs)
              date_format_nanoseconds(buf, nsecs)
              date_put(buf, 0x53) # 'S'
            end
          end

          to_utf8(buf)
        end

        # exsltFormatTwoDigits
        def date_format_two_digits(buf, num)
          return if num < 0 || num >= 100

          date_put(buf, 0x30 + (num / 10))
          date_put(buf, 0x30 + (num % 10))
        end

        # exsltFormatTime
        def date_format_time_part(buf, dt)
          date_format_two_digits(buf, dt.hour)
          date_put(buf, 0x3A)
          date_format_two_digits(buf, dt.min)
          date_put(buf, 0x3A)

          tmp = dt.sec.floor.to_f
          int_secs = tmp.to_i
          # Round to nearest to avoid issues with floating point precision, but don't carry
          # over so seconds stay below 60.
          nsecs = (((dt.sec - tmp) * 1_000_000_000) + 0.5).floor
          nsecs = 999_999_999 if nsecs > 999_999_999
          date_format_two_digits(buf, int_secs)
          date_format_nanoseconds(buf, nsecs)
        end

        # exsltDateFormatDateTime
        def date_format_date_time(dt)
          return nil if dt.nil? || !valid_datetime?(dt)

          buf = +"".b
          date_format_year_month_day(buf, dt)
          date_put(buf, 0x54)
          date_format_time_part(buf, dt)
          date_format_time_zone(buf, dt.tzo)
          to_utf8(buf)
        end

        # exsltDateFormatDate
        def date_format_date(dt)
          return nil if dt.nil? || !valid_datetime?(dt)

          buf = +"".b
          date_format_year_month_day(buf, dt)
          date_format_time_zone(buf, dt.tzo) if dt.tz_flag != 0 || dt.tzo != 0
          to_utf8(buf)
        end

        # exsltDateFormatTime
        def date_format_time(dt)
          return nil if dt.nil? || !valid_time?(dt)

          buf = +"".b
          date_format_time_part(buf, dt)
          date_format_time_zone(buf, dt.tzo) if dt.tz_flag != 0 || dt.tzo != 0
          to_utf8(buf)
        end

        # exsltDateFormat
        def date_format(dt)
          return nil if dt.nil?

          case dt.type
          when XS_DATETIME then return date_format_date_time(dt)
          when XS_DATE then return date_format_date(dt)
          when XS_TIME then return date_format_time(dt)
          end

          if dt.type & XS_GYEAR != 0
            buf = +"".b
            date_format_gyear(buf, dt.year)
            if dt.type == XS_GYEARMONTH
              date_put(buf, 0x2D)
              date_format_2digits(buf, dt.mon)
            end
            date_format_time_zone(buf, dt.tzo) if dt.tz_flag != 0 || dt.tzo != 0
            return to_utf8(buf)
          end

          nil
        end

        # ---- the current date --------------------------------------------------------------

        # strtol(str, NULL, 10): [value, ok] (ok is false on ERANGE)
        def date_strtol(str)
          m = /\A[ \t\n\v\f\r]*([+-]?)(\d*)/.match(str.b)
          digits = m[2]
          return [0, true] if digits.empty?

          val = digits.to_i
          val = -val if m[1] == "-"
          return [val, false] if val > LONG_MAX || val < LONG_MIN

          [val, true]
        end

        # exsltDateCurrent
        def date_current
          ret = DateVal.new(XS_DATETIME)

          local_tm = nil
          secs = nil
          # Allow the date and time to be set externally by an exported environment variable
          # to enable reproducible builds.
          if (source_date_epoch = ENV["SOURCE_DATE_EPOCH"])
            val, ok = date_strtol(source_date_epoch)
            if ok
              begin
                tm = Time.at(val).utc
                if tm.year - 1900 <= INT_MAX && tm.year - 1900 >= -INT_MAX - 1
                  local_tm = tm
                  secs = val
                end
              rescue RangeError
                local_tm = nil
              end
            end
          end

          if local_tm.nil?
            # get current time
            secs = Time.now.to_i
            local_tm = Time.at(secs)
          end

          ret.year = local_tm.year
          ret.mon = local_tm.month
          ret.day = local_tm.day
          ret.hour = local_tm.hour
          ret.min = local_tm.min
          # floating point seconds
          ret.sec = local_tm.sec.to_f

          # determine the time zone offset from local to gm time
          gm_tm = Time.at(secs).utc
          ret.tz_flag = 0

          local_s = (local_tm.hour * SECS_PER_HOUR) + (local_tm.min * SECS_PER_MIN) + local_tm.sec
          gm_s = (gm_tm.hour * SECS_PER_HOUR) + (gm_tm.min * SECS_PER_MIN) + gm_tm.sec

          ret.tzo = if local_tm.year < gm_tm.year
            cdiv(-((SECS_PER_DAY - local_s) + gm_s), 60)
          elsif local_tm.year > gm_tm.year
            cdiv((SECS_PER_DAY - gm_s) + local_s, 60)
          elsif local_tm.month < gm_tm.month
            cdiv(-((SECS_PER_DAY - local_s) + gm_s), 60)
          elsif local_tm.month > gm_tm.month
            cdiv((SECS_PER_DAY - gm_s) + local_s, 60)
          elsif local_tm.day < gm_tm.day
            cdiv(-((SECS_PER_DAY - local_s) + gm_s), 60)
          elsif local_tm.day > gm_tm.day
            cdiv((SECS_PER_DAY - gm_s) + local_s, 60)
          else
            cdiv(local_s - gm_s, 60)
          end

          ret
        end

        # ---- arithmetic --------------------------------------------------------------------

        # _exsltDateCastYMToDays
        def date_cast_ym_to_days(dt)
          y = dt.year
          if y <= 0
            ((y - 1) * 365) + (cdiv(y, 4) - cdiv(y, 100) + cdiv(y, 400)) +
              day_in_year(0, dt.mon, y) - 1
          else
            ((y - 1) * 365) + (cdiv(y - 1, 4) - cdiv(y - 1, 100) + cdiv(y - 1, 400)) +
              day_in_year(0, dt.mon, y)
          end
        end

        # TIME_TO_NUMBER
        def date_time_to_number(dt)
          ((dt.hour * SECS_PER_HOUR) + (dt.min * SECS_PER_MIN)).to_f + dt.sec
        end

        # _exsltDateTruncateDate
        def date_truncate_date(dt, type)
          return 1 if dt.nil?

          if type & XS_TIME != XS_TIME
            dt.hour = 0
            dt.min = 0
            dt.sec = 0.0
          end
          dt.day = 1 if type & XS_GDAY != XS_GDAY
          dt.mon = 1 if type & XS_GMONTH != XS_GMONTH
          dt.year = 0 if type & XS_GYEAR != XS_GYEAR
          dt.type = type
          0
        end

        # _exsltDateDayInWeek
        def date_day_in_week_calc(yday, yr)
          if yr <= 0
            # Compute modulus twice to avoid integer overflow
            ret = cmod(cmod(yr, 7) - 2 + (cdiv(yr, 4) - cdiv(yr, 100) + cdiv(yr, 400)) + yday, 7)
            ret += 7 if ret < 0
            ret
          else
            cmod((cmod(yr, 7) - 1) + (cdiv(yr - 1, 4) - cdiv(yr - 1, 100) + cdiv(yr - 1, 400)) + yday, 7)
          end
        end

        # _exsltDateAdd
        def date_add_calc(dt, dur)
          return nil if dt.nil? || dur.nil?

          ret = DateVal.new(dt.type)

          # month
          temp = dt.mon + cmod(dur.mon, 12)
          carry = cdiv(dur.mon, 12)
          if temp < 1
            temp += 12
            carry -= 1
          elsif temp > 12
            temp -= 12
            carry += 1
          end
          ret.mon = temp

          # year (may be modified later)
          # Add epochs from dur->day now to avoid overflow later and to speed up
          # pathological cases.
          carry += cdiv(dur.day, DAYS_PER_EPOCH) * YEARS_PER_EPOCH
          if (carry > 0 && dt.year > YEAR_MAX - carry) || (carry < 0 && dt.year < YEAR_MIN - carry)
            # Overflow
            return nil
          end
          ret.year = dt.year + carry

          # time zone
          ret.tzo = dt.tzo
          ret.tz_flag = dt.tz_flag

          # seconds
          sum = dt.sec + dur.sec
          ret.sec = XPath.fmod(sum, 60.0)
          carry = (sum / 60.0).to_i

          # minute
          temp = dt.min + cmod(carry, 60)
          carry = cdiv(carry, 60)
          if temp >= 60
            temp -= 60
            carry += 1
          end
          ret.min = temp

          # hours
          temp = dt.hour + cmod(carry, 24)
          carry = cdiv(carry, 24)
          if temp >= 24
            temp -= 24
            carry += 1
          end
          ret.hour = temp

          # days
          temp = if dt.day > max_day_in_month(ret.year, ret.mon)
            max_day_in_month(ret.year, ret.mon)
          elsif dt.day < 1
            1
          else
            dt.day
          end

          temp += cmod(dur.day, DAYS_PER_EPOCH) + carry

          loop do
            if temp < 1
              if ret.mon > 1
                ret.mon -= 1
              else
                return nil if ret.year == YEAR_MIN

                ret.mon = 12
                ret.year -= 1
              end
              temp += max_day_in_month(ret.year, ret.mon)
            elsif temp > max_day_in_month(ret.year, ret.mon)
              temp -= max_day_in_month(ret.year, ret.mon)
              if ret.mon < 12
                ret.mon += 1
              else
                return nil if ret.year == YEAR_MAX

                ret.mon = 1
                ret.year += 1
              end
            else
              break
            end
          end

          ret.day = temp

          # adjust the date/time type to the date values
          if ret.type != XS_DATETIME
            if ret.hour != 0 || ret.min != 0 || ret.sec != 0
              ret.type = XS_DATETIME
            elsif ret.type != XS_DATE
              if ret.day != 1
                ret.type = XS_DATE
              elsif ret.type != XS_GYEARMONTH && ret.mon != 1
                ret.type = XS_GYEARMONTH
              end
            end
          end

          ret
        end

        # _exsltDateDifference
        def date_difference_calc(x, y, flag)
          return nil if x.nil? || y.nil?
          return nil if x.type < XS_GYEAR || x.type > XS_DATETIME || y.type < XS_GYEAR || y.type > XS_DATETIME

          # the operand with the most specific format must be converted to the same type as
          # the operand with the least specific format.
          if x.type != y.type
            if x.type < y.type
              date_truncate_date(y, x.type)
            else
              date_truncate_date(x, y.type)
            end
          end

          ret = DateDurVal.new

          if (x.type == XS_GYEAR || x.type == XS_GYEARMONTH) && flag == 0
            # compute the difference in months
            if x.year >= cdiv(LONG_MAX, 24) || x.year <= cdiv(LONG_MIN, 24) ||
                y.year >= cdiv(LONG_MAX, 24) || y.year <= cdiv(LONG_MIN, 24)
              # Possible overflow.
              return nil
            end
            ret.mon = ((y.year - x.year) * 12) + (y.mon - x.mon)
          else
            if x.year > cdiv(LONG_MAX, 731) || x.year < cdiv(LONG_MIN, 731) ||
                y.year > cdiv(LONG_MAX, 731) || y.year < cdiv(LONG_MIN, 731)
              # Possible overflow.
              return nil
            end

            ret.sec = date_time_to_number(y) - date_time_to_number(x)
            ret.sec += (x.tzo - y.tzo) * SECS_PER_MIN
            carry = (ret.sec / SECS_PER_DAY).floor
            ret.sec -= carry * SECS_PER_DAY

            ret.day = date_cast_ym_to_days(y) - date_cast_ym_to_days(x)
            ret.day += y.day - x.day
            ret.day += carry
          end

          ret
        end

        # _exsltDateAddDurCalc: true on success
        def date_add_dur_calc(ret, x, y)
          # months
          return false if (x.mon > 0 && y.mon > LONG_MAX - x.mon) || (x.mon < 0 && y.mon <= LONG_MIN - x.mon)

          ret.mon = x.mon + y.mon

          # days
          return false if (x.day > 0 && y.day > LONG_MAX - x.day) || (x.day < 0 && y.day <= LONG_MIN - x.day)

          ret.day = x.day + y.day

          # seconds
          ret.sec = x.sec + y.sec
          if ret.sec >= SECS_PER_DAY
            return false if ret.day == LONG_MAX

            ret.sec -= SECS_PER_DAY
            ret.day += 1
          end

          # are the results indeterminate? i.e. how do you subtract days from months or years?
          if ret.day >= 0
            return false if (ret.day > 0 || ret.sec > 0) && ret.mon < 0
          elsif ret.mon > 0
            return false
          end
          true
        end

        # _exsltDateAddDuration
        def date_add_duration_calc(x, y)
          return nil if x.nil? || y.nil?

          ret = DateDurVal.new
          date_add_dur_calc(ret, x, y) ? ret : nil
        end

        # ---- the EXSLT functions -----------------------------------------------------------

        # exsltDateDateTime
        def date_date_time
          cur = date_current
          cur && date_format_date_time(cur)
        end

        # parses +date_time+ (or takes the current date if nil) and checks its type against
        # +types+; nil if invalid
        def date_parse_typed(date_time, types)
          return date_current if date_time.nil?

          dt = date_parse(date_time)
          return nil if dt.nil? || !types.include?(dt.type)

          dt
        end

        # exsltDateDate
        def date_date(date_time)
          dt = date_parse_typed(date_time, [XS_DATETIME, XS_DATE])
          dt && date_format_date(dt)
        end

        # exsltDateTime
        def date_time(date_time)
          dt = date_parse_typed(date_time, [XS_DATETIME, XS_TIME])
          dt && date_format_time(dt)
        end

        # exsltDateYear
        def date_year(date_time)
          dt = date_parse_typed(date_time, [XS_DATETIME, XS_DATE, XS_GYEARMONTH, XS_GYEAR])
          return NAN if dt.nil?

          year = dt.year
          year -= 1 if year <= 0 # Adjust for missing year 0.
          year.to_f
        end

        # exsltDateLeapYear: true/false, or NaN
        def date_leap_year(date_time)
          dt = date_parse_typed(date_time, [XS_DATETIME, XS_DATE, XS_GYEARMONTH, XS_GYEAR])
          return NAN if dt.nil?

          leap?(dt.year)
        end

        # exsltDateMonthInYear
        def date_month_in_year(date_time)
          dt = date_parse_typed(date_time, [XS_DATETIME, XS_DATE, XS_GYEARMONTH, XS_GMONTH, XS_GMONTHDAY])
          return NAN if dt.nil?

          dt.mon.to_f
        end

        # exsltDateMonthName
        def date_month_name(date_time)
          month = date_month_in_year(date_time)
          index = !month.nan? && month >= 1.0 && month <= 12.0 ? month.to_i : 0
          MONTH_NAMES[index]
        end

        # exsltDateMonthAbbreviation
        def date_month_abbreviation(date_time)
          month = date_month_in_year(date_time)
          index = !month.nan? && month >= 1.0 && month <= 12.0 ? month.to_i : 0
          MONTH_ABBREVIATIONS[index]
        end

        # exsltDateWeekInYear
        def date_week_in_year(date_time)
          dt = date_parse_typed(date_time, [XS_DATETIME, XS_DATE])
          return NAN if dt.nil?

          diy = day_in_year(dt.day, dt.mon, dt.year)

          # Determine day-in-week (0=Sun, 1=Mon, etc.) then adjust so Monday is the first
          # day-in-week
          diw = cmod(date_day_in_week_calc(diy, dt.year) + 6, 7)

          # ISO 8601 adjustment, 3 is Thu
          diy += (3 - diw)
          if diy < 1
            year = dt.year - 1
            year -= 1 if year == 0
            diy = day_in_year(31, 12, year) + diy
          elsif diy > day_in_year(31, 12, dt.year)
            diy -= day_in_year(31, 12, dt.year)
          end

          (cdiv(diy - 1, 7) + 1).to_f
        end

        # exsltDateWeekInMonth
        def date_week_in_month(date_time)
          dt = date_parse_typed(date_time, [XS_DATETIME, XS_DATE])
          return NAN if dt.nil?

          fdiy = day_in_year(1, dt.mon, dt.year)
          # Determine day-in-week (0=Sun, 1=Mon, etc.) then adjust so Monday is the first
          # day-in-week
          fdiw = cmod(date_day_in_week_calc(fdiy, dt.year) + 6, 7)

          (cdiv(dt.day + fdiw - 1, 7) + 1).to_f
        end

        # exsltDateDayInYear
        def date_day_in_year(date_time)
          dt = date_parse_typed(date_time, [XS_DATETIME, XS_DATE])
          return NAN if dt.nil?

          day_in_year(dt.day, dt.mon, dt.year).to_f
        end

        # exsltDateDayInMonth
        def date_day_in_month(date_time)
          dt = date_parse_typed(date_time, [XS_DATETIME, XS_DATE, XS_GMONTHDAY, XS_GDAY])
          return NAN if dt.nil?

          dt.day.to_f
        end

        # exsltDateDayOfWeekInMonth
        def date_day_of_week_in_month(date_time)
          dt = date_parse_typed(date_time, [XS_DATETIME, XS_DATE])
          return NAN if dt.nil?

          (cdiv(dt.day - 1, 7) + 1).to_f
        end

        # exsltDateDayInWeek
        def date_day_in_week(date_time)
          dt = date_parse_typed(date_time, [XS_DATETIME, XS_DATE])
          return NAN if dt.nil?

          diy = day_in_year(dt.day, dt.mon, dt.year)
          (date_day_in_week_calc(diy, dt.year) + 1).to_f
        end

        # exsltDateDayName
        def date_day_name(date_time)
          day = date_day_in_week(date_time)
          index = !day.nan? && day >= 1.0 && day <= 7.0 ? day.to_i : 0
          DAY_NAMES[index]
        end

        # exsltDateDayAbbreviation
        def date_day_abbreviation(date_time)
          day = date_day_in_week(date_time)
          index = !day.nan? && day >= 1.0 && day <= 7.0 ? day.to_i : 0
          DAY_ABBREVIATIONS[index]
        end

        # exsltDateHourInDay
        def date_hour_in_day(date_time)
          dt = date_parse_typed(date_time, [XS_DATETIME, XS_TIME])
          return NAN if dt.nil?

          dt.hour.to_f
        end

        # exsltDateMinuteInHour
        def date_minute_in_hour(date_time)
          dt = date_parse_typed(date_time, [XS_DATETIME, XS_TIME])
          return NAN if dt.nil?

          dt.min.to_f
        end

        # exsltDateSecondInMinute
        def date_second_in_minute(date_time)
          dt = date_parse_typed(date_time, [XS_DATETIME, XS_TIME])
          return NAN if dt.nil?

          dt.sec
        end

        # exsltDateAdd
        def date_add(xstr, ystr)
          return nil if xstr.nil? || ystr.nil?

          dt = date_parse(xstr)
          return nil if dt.nil? || dt.type < XS_GYEAR || dt.type > XS_DATETIME

          dur = date_parse_duration(ystr)
          return nil if dur.nil?

          res = date_add_calc(dt, dur)
          res && date_format(res)
        end

        # exsltDateAddDuration
        def date_add_duration(xstr, ystr)
          return nil if xstr.nil? || ystr.nil?

          x = date_parse_duration(xstr)
          return nil if x.nil?

          y = date_parse_duration(ystr)
          return nil if y.nil?

          res = date_add_duration_calc(x, y)
          res && date_format_duration(res)
        end

        # exsltDateSeconds
        def date_seconds(date_time)
          dur = nil
          if date_time.nil?
            dt = date_current
          else
            dt = date_parse(date_time)
            dur = date_parse_duration(date_time) if dt.nil?
          end

          ret = NAN
          if dt && dt.type >= XS_GYEAR
            # compute the difference between the given (or current) date and epoch date
            y = DateVal.new(XS_DATETIME)
            y.year = 1970
            y.mon = 1
            y.day = 1
            y.tz_flag = 1

            diff = date_difference_calc(y, dt, 1)
            ret = (diff.day.to_f * SECS_PER_DAY) + diff.sec if diff
          elsif dur && dur.mon == 0
            ret = (dur.day.to_f * SECS_PER_DAY) + dur.sec
          end
          ret
        end

        # exsltDateDifference
        def date_difference(xstr, ystr)
          return nil if xstr.nil? || ystr.nil?

          x = date_parse(xstr)
          return nil if x.nil?

          y = date_parse(ystr)
          return nil if y.nil?
          return nil if x.type < XS_GYEAR || x.type > XS_DATETIME || y.type < XS_GYEAR || y.type > XS_DATETIME

          dur = date_difference_calc(x, y, 0)
          dur && date_format_duration(dur)
        end

        LONG_MIN_F = LONG_MIN.to_f
        LONG_MAX_F = LONG_MAX.to_f

        # exsltDateDuration
        def date_duration(number)
          secs = number.nil? ? date_seconds(number) : XPath.string_eval_number(number)
          return nil if secs.nan?

          days = secs / SECS_PER_DAY
          days = days.floor.to_f if days.finite? # floor()
          return nil if days <= LONG_MIN_F || days >= LONG_MAX_F

          dur = DateDurVal.new
          dur.day = days.to_i
          dur.sec = secs - (days * SECS_PER_DAY)
          date_format_duration(dur)
        end

        # ---- XPath wrappers ----------------------------------------------------------------

        # the argument handling shared by the one-optional-string-argument functions: yields
        # the popped string (or nil) and returns false after an arity error
        def date_optional_arg(ctxt, nargs)
          if nargs < 0 || nargs > 1
            ctxt.xpath_err(XPath::INVALID_ARITY)
            return [false, nil]
          end
          dt = nil
          if nargs == 1
            dt = ctxt.pop_string
            if ctxt.error != XPath::EXPRESSION_OK
              ctxt.xpath_err(XPath::INVALID_TYPE)
              return [false, nil]
            end
          end
          [true, dt]
        end

        # exsltDateDateTimeFunction
        def date_date_time_function(ctxt, nargs)
          if nargs != 0
            ctxt.xpath_err(XPath::INVALID_ARITY)
            return
          end
          ret = date_date_time
          ctxt.value_push(ret.nil? ? +"" : ret)
        end

        # exsltDateDateFunction
        def date_date_function(ctxt, nargs)
          ok, dt = date_optional_arg(ctxt, nargs)
          return unless ok

          ret = date_date(dt)
          ctxt.value_push(ret.nil? ? +"" : ret)
        end

        # exsltDateTimeFunction
        def date_time_function(ctxt, nargs)
          ok, dt = date_optional_arg(ctxt, nargs)
          return unless ok

          ret = date_time(dt)
          ctxt.value_push(ret.nil? ? +"" : ret)
        end

        # exsltDateYearFunction
        def date_year_function(ctxt, nargs)
          ok, dt = date_optional_arg(ctxt, nargs)
          return unless ok

          ctxt.value_push(date_year(dt))
        end

        # exsltDateLeapYearFunction
        def date_leap_year_function(ctxt, nargs)
          ok, dt = date_optional_arg(ctxt, nargs)
          return unless ok

          ctxt.value_push(date_leap_year(dt))
        end

        # X_IN_Y / the name functions
        { month_in_year: :date_month_in_year, week_in_year: :date_week_in_year,
          week_in_month: :date_week_in_month, day_in_year: :date_day_in_year,
          day_in_month: :date_day_in_month, day_of_week_in_month: :date_day_of_week_in_month,
          day_in_week: :date_day_in_week, hour_in_day: :date_hour_in_day,
          minute_in_hour: :date_minute_in_hour, second_in_minute: :date_second_in_minute,
          month_name: :date_month_name, month_abbreviation: :date_month_abbreviation,
          day_name: :date_day_name, day_abbreviation: :date_day_abbreviation, }.each do |name, impl|
          define_method(:"date_#{name}_function") do |ctxt, nargs|
            ok, dt = date_optional_arg(ctxt, nargs)
            return unless ok

            ret = __send__(impl, dt)
            ctxt.value_push(ret.is_a?(String) ? ret.dup : ret)
          end
          module_function :"date_#{name}_function"
        end

        # exsltDateSecondsFunction
        def date_seconds_function(ctxt, nargs)
          if nargs > 1
            ctxt.xpath_err(XPath::INVALID_ARITY)
            return
          end
          str = nil
          if nargs == 1
            str = ctxt.pop_string
            if ctxt.error != XPath::EXPRESSION_OK
              ctxt.xpath_err(XPath::INVALID_TYPE)
              return
            end
          end
          ctxt.value_push(date_seconds(str))
        end

        # the shape of exsltDateAddFunction / AddDurationFunction / DifferenceFunction
        def date_binary_function(ctxt, nargs)
          if nargs != 2
            ctxt.xpath_err(XPath::INVALID_ARITY)
            return
          end
          ystr = ctxt.pop_string
          return if ctxt.error != XPath::EXPRESSION_OK

          xstr = ctxt.pop_string
          return if ctxt.error != XPath::EXPRESSION_OK

          ret = yield(xstr, ystr)
          ctxt.value_push(ret.nil? ? +"" : ret)
        end

        def date_add_function(ctxt, nargs)
          date_binary_function(ctxt, nargs) { |x, y| date_add(x, y) }
        end

        def date_add_duration_function(ctxt, nargs)
          date_binary_function(ctxt, nargs) { |x, y| date_add_duration(x, y) }
        end

        def date_difference_function(ctxt, nargs)
          date_binary_function(ctxt, nargs) { |x, y| date_difference(x, y) }
        end

        # exsltDateDurationFunction
        def date_duration_function(ctxt, nargs)
          ok, number = date_optional_arg(ctxt, nargs)
          return unless ok

          ret = date_duration(number)
          ctxt.value_push(ret.nil? ? +"" : ret)
        end

        # exsltDateSumFunction
        def date_sum_function(ctxt, nargs)
          if nargs != 1
            ctxt.xpath_err(XPath::INVALID_ARITY)
            return
          end

          ns = ctxt.pop_node_set
          return if ctxt.error != XPath::EXPRESSION_OK

          if ns.nil? || ns.empty?
            ctxt.value_push(+"")
            return
          end

          total = DateDurVal.new
          ns.each do |node|
            x = date_parse_duration(XPath.cast_node_to_string(node))
            if x.nil? || !date_add_dur_calc(total, total, x)
              ctxt.value_push(+"")
              return
            end
          end

          ret = date_format_duration(total)
          ctxt.value_push(ret.nil? ? +"" : ret)
        end

        DATE_FUNCTIONS = [
          ["add", :date_add_function],
          ["add-duration", :date_add_duration_function],
          ["date", :date_date_function],
          ["date-time", :date_date_time_function],
          ["day-abbreviation", :date_day_abbreviation_function],
          ["day-in-month", :date_day_in_month_function],
          ["day-in-week", :date_day_in_week_function],
          ["day-in-year", :date_day_in_year_function],
          ["day-name", :date_day_name_function],
          ["day-of-week-in-month", :date_day_of_week_in_month_function],
          ["difference", :date_difference_function],
          ["duration", :date_duration_function],
          ["hour-in-day", :date_hour_in_day_function],
          ["leap-year", :date_leap_year_function],
          ["minute-in-hour", :date_minute_in_hour_function],
          ["month-abbreviation", :date_month_abbreviation_function],
          ["month-in-year", :date_month_in_year_function],
          ["month-name", :date_month_name_function],
          ["second-in-minute", :date_second_in_minute_function],
          ["seconds", :date_seconds_function],
          ["sum", :date_sum_function],
          ["time", :date_time_function],
          ["week-in-month", :date_week_in_month_function],
          ["week-in-year", :date_week_in_year_function],
          ["year", :date_year_function],
        ].freeze

        # exsltDateRegister
        def date_register
          DATE_FUNCTIONS.each do |name, fn|
            XSLT.register_ext_module_function(name, DATE_NAMESPACE, method(fn))
          end
        end

        # exsltDateXpathCtxtRegister
        def date_xpath_ctxt_register(ctxt, prefix)
          xpath_ctxt_register(ctxt, prefix, DATE_NAMESPACE, DATE_FUNCTIONS)
        end
      end
    end
  end
end
