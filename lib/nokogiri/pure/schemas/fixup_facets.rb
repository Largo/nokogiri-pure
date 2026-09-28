# frozen_string_literal: true

require_relative "structs"
require_relative "macros"
require_relative "common"

# Port of xmlschemas.c (2.13.9) lines ~17157-18090: facet derivation (st-restrict-facets),
# union member type flattening, facet/whitespace optimisation flags and the simple type
# fixup stages.
module Nokogiri
  module Pure
    module Schemas
      extend self

      # FACET_RESTR_MUTUAL_ERR(fac1, fac2)
      def facet_restr_mutual_err(pctxt, fac1, fac2)
        p_custom_err_ext(pctxt, ErrCode::SCHEMAP_INVALID_FACET_VALUE,
          fac1, fac1.node,
          "It is an error for both '%s' and '%s' to be specified on the " \
          "same type definition",
          facet_type_to_string(fac1.type),
          facet_type_to_string(fac2.type), nil)
      end
      private :facet_restr_mutual_err

      # FACET_RESTR_ERR(fac1, msg)
      def facet_restr_err(pctxt, fac1, msg)
        p_custom_err(pctxt, ErrCode::SCHEMAP_INVALID_FACET_VALUE, fac1, fac1.node, msg, nil)
      end
      private :facet_restr_err

      # FACET_RESTR_FIXED_ERR(fac)
      def facet_restr_fixed_err(pctxt, fac)
        p_custom_err(pctxt, ErrCode::SCHEMAP_INVALID_FACET_VALUE, fac, fac.node,
          "The base type's facet is 'fixed', thus the value must not " \
          "differ", nil)
      end
      private :facet_restr_fixed_err

      # xmlSchemaDeriveFacetErr
      def derive_facet_err(pctxt, facet1, facet2, less_greater, or_equal, of_base)
        msg = +"'"
        msg << facet_type_to_string(facet1.type)
        msg << "' has to be"
        msg << " equal to" if less_greater == 0
        msg << (less_greater == 1 ? " greater than" : " less than")
        msg << " or equal to" if or_equal != 0
        msg << " '"
        msg << facet_type_to_string(facet2.type)
        msg << (of_base != 0 ? "' of the base type" : "'")

        p_custom_err(pctxt, ErrCode::SCHEMAP_INVALID_FACET_VALUE, facet1, nil, msg, nil)
      end

      # xmlSchemaDeriveAndValidateFacets
      # Schema Component Constraint: Simple Type Restriction (Facets) (st-restrict-facets)
      def derive_and_validate_facets(pctxt, type)
        base = type.base_type
        flength = ftotdig = ffracdig = fmaxlen = fminlen = nil
        fmininc = fmaxinc = fminexc = fmaxexc = nil
        bflength = bftotdig = bffracdig = bfmaxlen = bfminlen = nil
        bfmininc = bfmaxinc = bfminexc = bfmaxexc = nil

        # SPEC st-restrict-facets 1, 2: left out (satisfied by the derivation process).
        # SPEC st-restrict-facets 3: "The {facets} of R are the union of S and the {facets}
        # of B, eliminating duplicates. ..."
        return 0 if type.facet_set.nil? && base.facet_set.nil?

        last = type.facet_set
        last = last.next while last&.next

        cur = type.facet_set
        while cur
          facet = cur.facet
          case facet.type
          when XML_SCHEMA_FACET_LENGTH then flength = facet
          when XML_SCHEMA_FACET_MINLENGTH then fminlen = facet
          when XML_SCHEMA_FACET_MININCLUSIVE then fmininc = facet
          when XML_SCHEMA_FACET_MINEXCLUSIVE then fminexc = facet
          when XML_SCHEMA_FACET_MAXLENGTH then fmaxlen = facet
          when XML_SCHEMA_FACET_MAXINCLUSIVE then fmaxinc = facet
          when XML_SCHEMA_FACET_MAXEXCLUSIVE then fmaxexc = facet
          when XML_SCHEMA_FACET_TOTALDIGITS then ftotdig = facet
          when XML_SCHEMA_FACET_FRACTIONDIGITS then ffracdig = facet
          end
          cur = cur.next
        end
        cur = base.facet_set
        while cur
          facet = cur.facet
          case facet.type
          when XML_SCHEMA_FACET_LENGTH then bflength = facet
          when XML_SCHEMA_FACET_MINLENGTH then bfminlen = facet
          when XML_SCHEMA_FACET_MININCLUSIVE then bfmininc = facet
          when XML_SCHEMA_FACET_MINEXCLUSIVE then bfminexc = facet
          when XML_SCHEMA_FACET_MAXLENGTH then bfmaxlen = facet
          when XML_SCHEMA_FACET_MAXINCLUSIVE then bfmaxinc = facet
          when XML_SCHEMA_FACET_MAXEXCLUSIVE then bfmaxexc = facet
          when XML_SCHEMA_FACET_TOTALDIGITS then bftotdig = facet
          when XML_SCHEMA_FACET_FRACTIONDIGITS then bffracdig = facet
          end
          cur = cur.next
        end

        internal_error = lambda do
          internal_err(pctxt, "xmlSchemaDeriveAndValidateFacets", "an error occurred")
          -1
        end
        cmp = ->(a, b) { Types.compare_values(a.val, b.val) }

        # length and minLength or maxLength (2.2) + (3.2)
        if flength && (fminlen || fmaxlen)
          facet_restr_err(pctxt, flength, "It is an error for both 'length' and " \
            "either of 'minLength' or 'maxLength' to be specified on " \
            "the same type definition")
        end
        # Mutual exclusions in the same derivation step.
        # SCC "maxInclusive and maxExclusive"
        facet_restr_mutual_err(pctxt, fmaxinc, fmaxexc) if fmaxinc && fmaxexc
        # SCC "minInclusive and minExclusive"
        facet_restr_mutual_err(pctxt, fmininc, fminexc) if fmininc && fminexc

        if flength && bflength
          # SCC "length valid restriction" The values have to be equal.
          res = cmp.(flength, bflength)
          return internal_error.() if res == -2

          derive_facet_err(pctxt, flength, bflength, 0, 0, 1) if res != 0
          facet_restr_fixed_err(pctxt, flength) if res != 0 && bflength.fixed != 0
        end
        if fminlen && bfminlen
          # SCC "minLength valid restriction" minLength >= BASE minLength
          res = cmp.(fminlen, bfminlen)
          return internal_error.() if res == -2

          derive_facet_err(pctxt, fminlen, bfminlen, 1, 1, 1) if res == -1
          facet_restr_fixed_err(pctxt, fminlen) if res != 0 && bfminlen.fixed != 0
        end
        if fmaxlen && bfmaxlen
          # SCC "maxLength valid restriction" maxLength <= BASE minLength
          res = cmp.(fmaxlen, bfmaxlen)
          return internal_error.() if res == -2

          derive_facet_err(pctxt, fmaxlen, bfmaxlen, -1, 1, 1) if res == 1
          facet_restr_fixed_err(pctxt, fmaxlen) if res != 0 && bfmaxlen.fixed != 0
        end
        # SCC "length and minLength or maxLength"
        flength ||= bflength
        if flength
          fminlen ||= bfminlen
          if fminlen
            # (1.1) length >= minLength
            res = cmp.(flength, fminlen)
            return internal_error.() if res == -2

            derive_facet_err(pctxt, flength, fminlen, 1, 1, 0) if res == -1
          end
          fmaxlen ||= bfmaxlen
          if fmaxlen
            # (2.1) length <= maxLength
            res = cmp.(flength, fmaxlen)
            return internal_error.() if res == -2

            derive_facet_err(pctxt, flength, fmaxlen, -1, 1, 0) if res == 1
          end
        end
        if fmaxinc
          # "maxInclusive"
          if fmininc
            # SCC "maxInclusive >= minInclusive"
            res = cmp.(fmaxinc, fmininc)
            return internal_error.() if res == -2

            derive_facet_err(pctxt, fmaxinc, fmininc, 1, 1, 0) if res == -1
          end
          # SCC "maxInclusive valid restriction"
          if bfmaxinc
            # maxInclusive <= BASE maxInclusive
            res = cmp.(fmaxinc, bfmaxinc)
            return internal_error.() if res == -2

            derive_facet_err(pctxt, fmaxinc, bfmaxinc, -1, 1, 1) if res == 1
            facet_restr_fixed_err(pctxt, fmaxinc) if res != 0 && bfmaxinc.fixed != 0
          end
          if bfmaxexc
            # maxInclusive < BASE maxExclusive
            res = cmp.(fmaxinc, bfmaxexc)
            return internal_error.() if res == -2

            derive_facet_err(pctxt, fmaxinc, bfmaxexc, -1, 0, 1) if res != -1
          end
          if bfmininc
            # maxInclusive >= BASE minInclusive
            res = cmp.(fmaxinc, bfmininc)
            return internal_error.() if res == -2

            derive_facet_err(pctxt, fmaxinc, bfmininc, 1, 1, 1) if res == -1
          end
          if bfminexc
            # maxInclusive > BASE minExclusive
            res = cmp.(fmaxinc, bfminexc)
            return internal_error.() if res == -2

            derive_facet_err(pctxt, fmaxinc, bfminexc, 1, 0, 1) if res != 1
          end
        end
        if fmaxexc
          # "maxExclusive >= minExclusive"
          if fminexc
            res = cmp.(fmaxexc, fminexc)
            return internal_error.() if res == -2

            derive_facet_err(pctxt, fmaxexc, fminexc, 1, 1, 0) if res == -1
          end
          # "maxExclusive valid restriction"
          if bfmaxexc
            # maxExclusive <= BASE maxExclusive
            res = cmp.(fmaxexc, bfmaxexc)
            return internal_error.() if res == -2

            derive_facet_err(pctxt, fmaxexc, bfmaxexc, -1, 1, 1) if res == 1
            facet_restr_fixed_err(pctxt, fmaxexc) if res != 0 && bfmaxexc.fixed != 0
          end
          if bfmaxinc
            # maxExclusive <= BASE maxInclusive
            res = cmp.(fmaxexc, bfmaxinc)
            return internal_error.() if res == -2

            derive_facet_err(pctxt, fmaxexc, bfmaxinc, -1, 1, 1) if res == 1
          end
          if bfmininc
            # maxExclusive > BASE minInclusive
            res = cmp.(fmaxexc, bfmininc)
            return internal_error.() if res == -2

            derive_facet_err(pctxt, fmaxexc, bfmininc, 1, 0, 1) if res != 1
          end
          if bfminexc
            # maxExclusive > BASE minExclusive
            res = cmp.(fmaxexc, bfminexc)
            return internal_error.() if res == -2

            derive_facet_err(pctxt, fmaxexc, bfminexc, 1, 0, 1) if res != 1
          end
        end
        if fminexc
          # "minExclusive < maxInclusive"
          if fmaxinc
            res = cmp.(fminexc, fmaxinc)
            return internal_error.() if res == -2

            derive_facet_err(pctxt, fminexc, fmaxinc, -1, 0, 0) if res != -1
          end
          # "minExclusive valid restriction"
          if bfminexc
            # minExclusive >= BASE minExclusive
            res = cmp.(fminexc, bfminexc)
            return internal_error.() if res == -2

            derive_facet_err(pctxt, fminexc, bfminexc, 1, 1, 1) if res == -1
            facet_restr_fixed_err(pctxt, fminexc) if res != 0 && bfminexc.fixed != 0
          end
          if bfmaxinc
            # minExclusive <= BASE maxInclusive
            res = cmp.(fminexc, bfmaxinc)
            return internal_error.() if res == -2

            derive_facet_err(pctxt, fminexc, bfmaxinc, -1, 1, 1) if res == 1
          end
          if bfmininc
            # minExclusive >= BASE minInclusive
            res = cmp.(fminexc, bfmininc)
            return internal_error.() if res == -2

            derive_facet_err(pctxt, fminexc, bfmininc, 1, 1, 1) if res == -1
          end
          if bfmaxexc
            # minExclusive < BASE maxExclusive
            res = cmp.(fminexc, bfmaxexc)
            return internal_error.() if res == -2

            derive_facet_err(pctxt, fminexc, bfmaxexc, -1, 0, 1) if res != -1
          end
        end
        if fmininc
          # "minInclusive < maxExclusive"
          if fmaxexc
            res = cmp.(fmininc, fmaxexc)
            return internal_error.() if res == -2

            derive_facet_err(pctxt, fmininc, fmaxexc, -1, 0, 0) if res != -1
          end
          # "minExclusive valid restriction"
          if bfmininc
            # minInclusive >= BASE minInclusive
            res = cmp.(fmininc, bfmininc)
            return internal_error.() if res == -2

            derive_facet_err(pctxt, fmininc, bfmininc, 1, 1, 1) if res == -1
            facet_restr_fixed_err(pctxt, fmininc) if res != 0 && bfmininc.fixed != 0
          end
          if bfmaxinc
            # minInclusive <= BASE maxInclusive
            res = cmp.(fmininc, bfmaxinc)
            return internal_error.() if res == -2

            derive_facet_err(pctxt, fmininc, bfmaxinc, -1, 1, 1) if res == 1
          end
          if bfminexc
            # minInclusive > BASE minExclusive
            res = cmp.(fmininc, bfminexc)
            return internal_error.() if res == -2

            derive_facet_err(pctxt, fmininc, bfminexc, 1, 0, 1) if res != 1
          end
          if bfmaxexc
            # minInclusive < BASE maxExclusive
            res = cmp.(fmininc, bfmaxexc)
            return internal_error.() if res == -2

            derive_facet_err(pctxt, fmininc, bfmaxexc, -1, 0, 1) if res != -1
          end
        end
        if ftotdig && bftotdig
          # SCC " totalDigits valid restriction" totalDigits <= BASE totalDigits
          res = cmp.(ftotdig, bftotdig)
          return internal_error.() if res == -2

          derive_facet_err(pctxt, ftotdig, bftotdig, -1, 1, 1) if res == 1
          facet_restr_fixed_err(pctxt, ftotdig) if res != 0 && bftotdig.fixed != 0
        end
        if ffracdig && bffracdig
          # SCC  "fractionDigits valid restriction" fractionDigits <= BASE fractionDigits
          res = cmp.(ffracdig, bffracdig)
          return internal_error.() if res == -2

          derive_facet_err(pctxt, ffracdig, bffracdig, -1, 1, 1) if res == 1
          facet_restr_fixed_err(pctxt, ffracdig) if res != 0 && bffracdig.fixed != 0
        end
        # SCC "fractionDigits less than or equal to totalDigits"
        ftotdig ||= bftotdig
        ffracdig ||= bffracdig
        if ftotdig && ffracdig
          res = cmp.(ffracdig, ftotdig)
          return internal_error.() if res == -2

          derive_facet_err(pctxt, ffracdig, ftotdig, -1, 1, 0) if res == 1
        end
        # *Enumerations* and *Patterns* won't be added here.
        cur = base.facet_set
        while cur
          bfacet = cur.facet
          # Special handling of enumerations and patterns.
          if bfacet.type == XML_SCHEMA_FACET_PATTERN || bfacet.type == XML_SCHEMA_FACET_ENUMERATION
            cur = cur.next
            next
          end
          # Search for a duplicate facet in the current type.
          link = type.facet_set
          while link
            facet = link.facet
            if facet.type == bfacet.type
              if facet.type == XML_SCHEMA_FACET_WHITESPACE
                # The whitespace must be stronger.
                if facet.whitespace < bfacet.whitespace
                  facet_restr_err(pctxt, facet,
                    "The 'whitespace' value has to be equal to " \
                    "or stronger than the 'whitespace' value of " \
                    "the base type")
                end
                if bfacet.fixed != 0 && facet.whitespace != bfacet.whitespace
                  facet_restr_fixed_err(pctxt, facet)
                end
              end
              # Duplicate found.
              break
            end
            link = link.next
          end
          # If no duplicate was found: add the base types's facet to the set.
          if link.nil?
            link = SchemaFacetLink.new(facet: cur.facet, next: nil)
            if last.nil?
              type.facet_set = link
            else
              last.next = link
            end
            last = link
          end
          cur = cur.next
        end
        0
      end

      # xmlSchemaFinishMemberTypeDefinitionsProperty
      def finish_member_type_definitions_property(pctxt, type)
        # The actual value is then formed by replacing any union type definition in the
        # `explicit members` with the members of their {member type definitions}, in order.
        link = type.member_types
        while link
          type_fixup(link.type, pctxt) if wxs_is_type_not_fixed(link.type)

          if wxs_is_union(link.type)
            sub_link = get_union_simple_type_member_types(link.type)
            unless sub_link.nil?
              link.type = sub_link.type
              unless sub_link.next.nil?
                last_link = link.next
                sub_link = sub_link.next
                prev_link = link
                while sub_link
                  new_link = SchemaTypeLink.new(type: sub_link.type)
                  prev_link.next = new_link
                  prev_link = new_link
                  new_link.next = last_link

                  sub_link = sub_link.next
                end
              end
            end
          end
          link = link.next
        end
        0
      end

      # xmlSchemaTypeFixupOptimFacets
      def type_fixup_optim_facets(type)
        need_val = false
        norm_val = false
        has = (type.base_type.flags & XML_SCHEMAS_TYPE_HAS_FACETS) != 0
        if has
          need_val = (type.base_type.flags & XML_SCHEMAS_TYPE_FACETSNEEDVALUE) != 0
          norm_val = (type.base_type.flags & XML_SCHEMAS_TYPE_NORMVALUENEEDED) != 0
        end
        fac = type.facets
        while fac
          case fac.type
          when XML_SCHEMA_FACET_WHITESPACE
            nil
          when XML_SCHEMA_FACET_PATTERN
            norm_val = true
            has = true
          when XML_SCHEMA_FACET_ENUMERATION
            need_val = true
            norm_val = true
            has = true
          else
            has = true
          end
          fac = fac.next
        end
        type.flags |= XML_SCHEMAS_TYPE_NORMVALUENEEDED if norm_val
        type.flags |= XML_SCHEMAS_TYPE_FACETSNEEDVALUE if need_val
        type.flags |= XML_SCHEMAS_TYPE_HAS_FACETS if has

        if has && !need_val && wxs_is_atomic(type)
          prim = get_primitive_type(type)
          # OPTIMIZE VAL TODO: Some facets need a computed value.
          if prim.built_in_type != XML_SCHEMAS_ANYSIMPLETYPE &&
              prim.built_in_type != XML_SCHEMAS_STRING
            type.flags |= XML_SCHEMAS_TYPE_FACETSNEEDVALUE
          end
        end
      end

      # xmlSchemaTypeFixupWhitespace
      def type_fixup_whitespace(type)
        # Evaluate the whitespace-facet value.
        if wxs_is_list(type)
          type.flags |= XML_SCHEMAS_TYPE_WHITESPACE_COLLAPSE
          return 0
        elsif wxs_is_union(type)
          return 0
        end

        lin = type.facet_set
        while lin
          if lin.facet.type == XML_SCHEMA_FACET_WHITESPACE
            case lin.facet.whitespace
            when XML_SCHEMAS_FACET_PRESERVE
              type.flags |= XML_SCHEMAS_TYPE_WHITESPACE_PRESERVE
            when XML_SCHEMAS_FACET_REPLACE
              type.flags |= XML_SCHEMAS_TYPE_WHITESPACE_REPLACE
            when XML_SCHEMAS_FACET_COLLAPSE
              type.flags |= XML_SCHEMAS_TYPE_WHITESPACE_COLLAPSE
            else
              return -1
            end
            return 0
          end
          lin = lin.next
        end
        # For all `atomic` datatypes other than string (and types `derived` by `restriction`
        # from it) the value of whiteSpace is fixed to collapse
        anc = type.base_type
        while !anc.nil? && anc.built_in_type != XML_SCHEMAS_ANYTYPE
          if anc.type == XML_SCHEMA_TYPE_BASIC
            if anc.built_in_type == XML_SCHEMAS_NORMSTRING
              type.flags |= XML_SCHEMAS_TYPE_WHITESPACE_REPLACE
            elsif anc.built_in_type == XML_SCHEMAS_STRING ||
                anc.built_in_type == XML_SCHEMAS_ANYSIMPLETYPE
              type.flags |= XML_SCHEMAS_TYPE_WHITESPACE_PRESERVE
            else
              type.flags |= XML_SCHEMAS_TYPE_WHITESPACE_COLLAPSE
            end
            break
          end
          anc = anc.base_type
        end
        0
      end

      # xmlSchemaFixupSimpleTypeStageOne
      def fixup_simple_type_stage_one(pctxt, type)
        return 0 if type.type != XML_SCHEMA_TYPE_SIMPLE
        return 0 unless wxs_is_type_not_fixed_1(type)

        type.flags |= XML_SCHEMAS_TYPE_FIXUP_1

        if wxs_is_list(type)
          # Corresponds to <simpleType><list>...
          if type.subtypes.nil?
            internal_err(pctxt, "xmlSchemaFixupSimpleTypeStageOne",
              "list type has no item-type assigned")
            return -1
          end
        elsif wxs_is_union(type)
          # Corresponds to <simpleType><union>...
          if type.member_types.nil?
            internal_err(pctxt, "xmlSchemaFixupSimpleTypeStageOne",
              "union type has no member-types assigned")
            return -1
          end
        else
          # Corresponds to <simpleType><restriction>...
          if type.base_type.nil?
            internal_err(pctxt, "xmlSchemaFixupSimpleTypeStageOne",
              "type has no base-type assigned")
            return -1
          end
          if wxs_is_type_not_fixed_1(type.base_type)
            return -1 if fixup_simple_type_stage_one(pctxt, type.base_type) == -1
          end
          # Variety: If the <restriction> alternative is chosen, then the {variety} of the
          # {base type definition}.
          if wxs_is_atomic(type.base_type)
            type.flags |= XML_SCHEMAS_TYPE_VARIETY_ATOMIC
          elsif wxs_is_list(type.base_type)
            type.flags |= XML_SCHEMAS_TYPE_VARIETY_LIST
            # Inherit the itemType.
            type.subtypes = type.base_type.subtypes
          elsif wxs_is_union(type.base_type)
            type.flags |= XML_SCHEMAS_TYPE_VARIETY_UNION
            # NOTE that we won't assign the memberTypes of the base.
          end
        end
        0
      end

      # xmlSchemaFixupSimpleTypeStageTwo
      # 3.14.6 Constraints on Simple Type Definition Schema Components
      def fixup_simple_type_stage_two(pctxt, type)
        olderrs = pctxt.nberrors

        return -1 if type.type != XML_SCHEMA_TYPE_SIMPLE
        return 0 unless wxs_is_type_not_fixed(type)

        type.flags |= XML_SCHEMAS_TYPE_INTERNAL_RESOLVED
        type.content_type = XML_SCHEMA_CONTENT_SIMPLE

        if type.base_type.nil?
          internal_err(pctxt, "xmlSchemaFixupSimpleTypeStageTwo", "missing baseType")
          return -1
        end
        type_fixup(type.base_type, pctxt) if wxs_is_type_not_fixed(type.base_type)
        # If a member type of a union is a union itself, we need to substitute that member
        # type for its member types.
        if !type.member_types.nil? && finish_member_type_definitions_property(pctxt, type) == -1
          return -1
        end

        catch(:exit_error) do
          # Schema Component Constraint: Simple Type Definition Properties Correct
          # (st-props-correct)
          res = check_st_props_correct(pctxt, type)
          return -1 if res == -1
          throw :exit_error if res != 0

          # Schema Component Constraint: Derivation Valid (Restriction, Simple)
          # (cos-st-restricts)
          res = check_cosst_restricts(pctxt, type)
          return -1 if res == -1
          throw :exit_error if res != 0

          # Schema Component Constraint: Simple Type Restriction (Facets)
          # (st-restrict-facets)
          res = check_facet_values(type, pctxt)
          return -1 if res == -1
          throw :exit_error if res != 0

          if !type.facet_set.nil? || !type.base_type.facet_set.nil?
            res = derive_and_validate_facets(pctxt, type)
            return -1 if res == -1
            throw :exit_error if res != 0
          end
          # Whitespace value.
          res = type_fixup_whitespace(type)
          return -1 if res == -1
          throw :exit_error if res != 0

          type_fixup_optim_facets(type)
        end
        # exit_error:
        return pctxt.err if olderrs != pctxt.nberrors

        0
      end
    end
  end
end
