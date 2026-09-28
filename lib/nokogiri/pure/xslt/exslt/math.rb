# frozen_string_literal: true

# Port of libexslt/math.c: math:min/max/highest/lowest/constant/random/abs/sqrt/power/log/
# sin/cos/tan/asin/acos/atan/atan2/exp.
#
# The libm wrappers below reproduce C semantics where Ruby's Math differs (Ruby raises
# Math::DomainError or returns a Complex where C returns NaN, and Math.sqrt(-0.0) is +0.0).

module Nokogiri
  module Pure
    module XSLT
      module EXSLT
        NAN = Float::NAN

        module_function

        # ---- C libm semantics ----------------------------------------------------------------

        def c_sqrt(x)
          return x if x == 0.0 # keeps the sign of -0.0
          return NAN if x < 0

          Math.sqrt(x)
        end

        def c_log(x)
          return NAN if x < 0

          Math.log(x)
        end

        def c_asin(x)
          return NAN if x < -1.0 || x > 1.0

          Math.asin(x)
        end

        def c_acos(x)
          return NAN if x < -1.0 || x > 1.0

          Math.acos(x)
        end

        def c_pow(base, power)
          if base < 0 && power.finite? && power != power.round
            # Ruby would return a Complex; C pow() gives NaN (or +-inf/0 for -inf)
            return base.infinite? ? (power > 0 ? Float::INFINITY : 0.0) : NAN
          end

          base**power
        end

        # ---- node-set functions ---------------------------------------------------------------

        # exsltMathMin
        def math_min(ns)
          return NAN if ns.nil? || ns.empty?

          ret = XPath.cast_node_to_number(ns[0])
          return NAN if ret.nan?

          i = 1
          while i < ns.length
            cur = XPath.cast_node_to_number(ns[i])
            return NAN if cur.nan?

            ret = cur if cur < ret
            i += 1
          end
          ret
        end

        # exsltMathMinFunction
        def math_min_function(ctxt, nargs)
          if nargs != 1
            XSLT.generic_error("math:min: invalid number of arguments\n")
            ctxt.error = XPath::INVALID_ARITY
            return
          end
          ns = ctxt.pop_node_set
          return if ctxt.error != XPath::EXPRESSION_OK

          ctxt.value_push(math_min(ns))
        end

        # exsltMathMax
        def math_max(ns)
          return NAN if ns.nil? || ns.empty?

          ret = XPath.cast_node_to_number(ns[0])
          return NAN if ret.nan?

          i = 1
          while i < ns.length
            cur = XPath.cast_node_to_number(ns[i])
            return NAN if cur.nan?

            ret = cur if cur > ret
            i += 1
          end
          ret
        end

        # exsltMathMaxFunction
        def math_max_function(ctxt, nargs)
          if nargs != 1
            ctxt.xpath_err(XPath::INVALID_ARITY)
            return
          end
          ns = ctxt.pop_node_set
          return if ctxt.error != XPath::EXPRESSION_OK

          ctxt.value_push(math_max(ns))
        end

        # exsltMathHighest
        def math_highest(ns)
          ret = []
          return ret if ns.nil? || ns.empty?

          max = XPath.cast_node_to_number(ns[0])
          return ret if max.nan?

          XPath.node_set_add_unique(ret, ns[0])
          i = 1
          while i < ns.length
            cur = XPath.cast_node_to_number(ns[i])
            if cur.nan?
              ret.clear
              return ret
            end
            if cur < max
              i += 1
              next
            end
            if cur > max
              max = cur
              ret.clear
            end
            XPath.node_set_add_unique(ret, ns[i])
            i += 1
          end
          ret
        end

        # exsltMathHighestFunction
        def math_highest_function(ctxt, nargs)
          if nargs != 1
            ctxt.xpath_err(XPath::INVALID_ARITY)
            return
          end
          ns = ctxt.pop_node_set
          return if ctxt.error != XPath::EXPRESSION_OK

          ctxt.value_push(math_highest(ns))
        end

        # exsltMathLowest
        def math_lowest(ns)
          ret = []
          return ret if ns.nil? || ns.empty?

          min = XPath.cast_node_to_number(ns[0])
          return ret if min.nan?

          XPath.node_set_add_unique(ret, ns[0])
          i = 1
          while i < ns.length
            cur = XPath.cast_node_to_number(ns[i])
            if cur.nan?
              ret.clear
              return ret
            end
            if cur > min
              i += 1
              next
            end
            if cur < min
              min = cur
              ret.clear
            end
            XPath.node_set_add_unique(ret, ns[i])
            i += 1
          end
          ret
        end

        # exsltMathLowestFunction
        def math_lowest_function(ctxt, nargs)
          if nargs != 1
            ctxt.xpath_err(XPath::INVALID_ARITY)
            return
          end
          ns = ctxt.pop_node_set
          return if ctxt.error != XPath::EXPRESSION_OK

          ctxt.value_push(math_lowest(ns))
        end

        # ---- constants ------------------------------------------------------------------------

        MATH_CONSTANTS = {
          "PI" => "3.1415926535897932384626433832795028841971693993751",
          "E" => "2.71828182845904523536028747135266249775724709369996",
          "SQRRT2" => "1.41421356237309504880168872420969807856967187537694",
          "LN2" => "0.69314718055994530941723212145817656807550013436025",
          "LN10" => "2.30258509299404568402",
          "LOG2E" => "1.4426950408889634074",
          "SQRT1_2" => "0.70710678118654752440",
        }.freeze

        # exsltMathConstant
        def math_constant(name, precision)
          return NAN if name.nil? || precision.nan? || precision < 1.0

          digits = MATH_CONSTANTS[name]
          return NAN if digits.nil?

          len = digits.length
          len = precision.to_i if precision <= len
          XPath.string_eval_number(digits[0, len])
        end

        # exsltMathConstantFunction
        def math_constant_function(ctxt, nargs)
          if nargs != 2
            ctxt.xpath_err(XPath::INVALID_ARITY)
            return
          end
          ret = ctxt.pop_number
          return if ctxt.error != XPath::EXPRESSION_OK

          name = ctxt.pop_string
          return if ctxt.error != XPath::EXPRESSION_OK

          ctxt.value_push(math_constant(name, ret))
        end

        # exsltMathRandom: rand() / RAND_MAX
        def math_random
          Random.rand
        end

        # exsltMathRandomFunction
        def math_random_function(ctxt, nargs)
          if nargs != 0
            ctxt.xpath_err(XPath::INVALID_ARITY)
            return
          end
          ctxt.value_push(math_random)
        end

        # ---- one-argument functions -----------------------------------------------------------

        def math_abs(num) = num.nan? ? NAN : num.abs
        def math_sqrt(num) = num.nan? ? NAN : c_sqrt(num)
        def math_log(num) = num.nan? ? NAN : c_log(num)
        def math_sin(num) = num.nan? ? NAN : Math.sin(num)
        def math_cos(num) = num.nan? ? NAN : Math.cos(num)
        def math_tan(num) = num.nan? ? NAN : Math.tan(num)
        def math_asin(num) = num.nan? ? NAN : c_asin(num)
        def math_acos(num) = num.nan? ? NAN : c_acos(num)
        def math_atan(num) = num.nan? ? NAN : Math.atan(num)
        def math_exp(num) = num.nan? ? NAN : Math.exp(num)

        # exsltMathPower
        def math_power(base, power)
          return NAN if base.nan? || power.nan?

          c_pow(base, power)
        end

        # exsltMathAtan2
        def math_atan2(y, x)
          return NAN if y.nan? || x.nan?

          Math.atan2(y, x)
        end

        # the common shape of exsltMath{Abs,Sqrt,Log,Sin,...}Function
        def math_unary(ctxt, nargs)
          if nargs != 1
            ctxt.xpath_err(XPath::INVALID_ARITY)
            return
          end
          ret = ctxt.pop_number
          return if ctxt.error != XPath::EXPRESSION_OK

          ctxt.value_push(yield(ret))
        end

        def math_abs_function(ctxt, nargs) = math_unary(ctxt, nargs) { |n| math_abs(n) }
        def math_sqrt_function(ctxt, nargs) = math_unary(ctxt, nargs) { |n| math_sqrt(n) }
        def math_log_function(ctxt, nargs) = math_unary(ctxt, nargs) { |n| math_log(n) }
        def math_sin_function(ctxt, nargs) = math_unary(ctxt, nargs) { |n| math_sin(n) }
        def math_cos_function(ctxt, nargs) = math_unary(ctxt, nargs) { |n| math_cos(n) }
        def math_tan_function(ctxt, nargs) = math_unary(ctxt, nargs) { |n| math_tan(n) }
        def math_asin_function(ctxt, nargs) = math_unary(ctxt, nargs) { |n| math_asin(n) }
        def math_acos_function(ctxt, nargs) = math_unary(ctxt, nargs) { |n| math_acos(n) }
        def math_atan_function(ctxt, nargs) = math_unary(ctxt, nargs) { |n| math_atan(n) }
        def math_exp_function(ctxt, nargs) = math_unary(ctxt, nargs) { |n| math_exp(n) }

        # exsltMathPowerFunction
        def math_power_function(ctxt, nargs)
          if nargs != 2
            ctxt.xpath_err(XPath::INVALID_ARITY)
            return
          end
          ret = ctxt.pop_number
          return if ctxt.error != XPath::EXPRESSION_OK

          base = ctxt.pop_number
          return if ctxt.error != XPath::EXPRESSION_OK

          ctxt.value_push(math_power(base, ret))
        end

        # exsltMathAtan2Function
        def math_atan2_function(ctxt, nargs)
          if nargs != 2
            ctxt.xpath_err(XPath::INVALID_ARITY)
            return
          end
          x = ctxt.pop_number
          return if ctxt.error != XPath::EXPRESSION_OK

          y = ctxt.pop_number
          return if ctxt.error != XPath::EXPRESSION_OK

          ctxt.value_push(math_atan2(y, x))
        end

        MATH_FUNCTIONS = [
          ["min", :math_min_function], ["max", :math_max_function],
          ["highest", :math_highest_function], ["lowest", :math_lowest_function],
          ["constant", :math_constant_function], ["random", :math_random_function],
          ["abs", :math_abs_function], ["sqrt", :math_sqrt_function],
          ["power", :math_power_function], ["log", :math_log_function],
          ["sin", :math_sin_function], ["cos", :math_cos_function], ["tan", :math_tan_function],
          ["asin", :math_asin_function], ["acos", :math_acos_function],
          ["atan", :math_atan_function], ["atan2", :math_atan2_function],
          ["exp", :math_exp_function],
        ].freeze

        # exsltMathRegister
        def math_register
          MATH_FUNCTIONS.each do |name, fn|
            XSLT.register_ext_module_function(name, MATH_NAMESPACE, method(fn))
          end
        end

        # exsltMathXpathCtxtRegister: 0 on success, -1 on failure
        def math_xpath_ctxt_register(ctxt, prefix)
          xpath_ctxt_register(ctxt, prefix, MATH_NAMESPACE,
            MATH_FUNCTIONS.reject { |n, _| n == "constant" } + [["constant", :math_constant_function]])
        end

        # the shared shape of the exslt*XpathCtxtRegister functions
        def xpath_ctxt_register(ctxt, prefix, uri, functions)
          return -1 if ctxt.nil? || prefix.nil?
          return -1 if ctxt.register_ns(prefix, uri) != 0

          functions.each do |name, fn|
            return -1 if ctxt.register_func_ns(name, uri, method(fn)) != 0
          end
          0
        end
      end
    end
  end
end
