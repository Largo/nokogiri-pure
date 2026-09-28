# frozen_string_literal: true

require_relative "structs"
require_relative "macros"
require_relative "common"
require_relative "constraints"

# Port of xmlschemas.c (2.13.9) lines ~15155-16760: st-props-correct, cos-st-restricts,
# cos-valid-default (parser side), ct-props-correct, cos-ct-derived-ok, cos-ct-extends,
# derivation-ok-restriction, src-ct. (The particle restriction checks
# (rcase-*, cos-particle-restrict) are under ENABLE_PARTICLE_RESTRICTION in C, which is off
# in a default build, so they are not ported.)
module Nokogiri
  module Pure
    module Schemas
      extend self

      # xmlSchemaCheckSTPropsCorrect
      # Checks st-props-correct.
      # Returns 0 if the properties are correct, if not, a positive error code and -1 on
      # internal errors.
      def check_st_props_correct(ctxt, type)
        base_type = type.base_type
        # Schema Component Constraint: Simple Type Definition Properties Correct
        if base_type.nil?
          p_custom_err(ctxt, ErrCode::SCHEMAP_ST_PROPS_CORRECT_1,
            type, nil, "No base type existent", nil)
          return ErrCode::SCHEMAP_ST_PROPS_CORRECT_1
        end
        unless wxs_is_simple(base_type)
          p_custom_err(ctxt, ErrCode::SCHEMAP_ST_PROPS_CORRECT_1,
            type, nil,
            "The base type '%s' is not a simple type",
            get_component_q_name(base_type))
          return ErrCode::SCHEMAP_ST_PROPS_CORRECT_1
        end
        if (wxs_is_list(type) || wxs_is_union(type)) &&
            !wxs_is_restriction(type) &&
            (!wxs_is_any_simple_type(base_type) && base_type.type != XML_SCHEMA_TYPE_SIMPLE)
          p_custom_err(ctxt, ErrCode::SCHEMAP_ST_PROPS_CORRECT_1,
            type, nil,
            "A type, derived by list or union, must have " \
            "the simple ur-type definition as base type, not '%s'",
            get_component_q_name(base_type))
          return ErrCode::SCHEMAP_ST_PROPS_CORRECT_1
        end
        # Variety: One of {atomic, list, union}.
        if !wxs_is_atomic(type) && !wxs_is_union(type) && !wxs_is_list(type)
          p_custom_err(ctxt, ErrCode::SCHEMAP_ST_PROPS_CORRECT_1,
            type, nil, "The variety is absent", nil)
          return ErrCode::SCHEMAP_ST_PROPS_CORRECT_1
        end
        # 3 The {final} of the {base type definition} must not contain restriction.
        if type_final_contains(base_type, XML_SCHEMAS_TYPE_FINAL_RESTRICTION) != 0
          p_custom_err(ctxt, ErrCode::SCHEMAP_ST_PROPS_CORRECT_3,
            type, nil,
            "The 'final' of its base type '%s' must not contain " \
            "'restriction'",
            get_component_q_name(base_type))
          return ErrCode::SCHEMAP_ST_PROPS_CORRECT_3
        end
        # 2 ... is done in xmlSchemaCheckTypeDefCircular().
        0
      end

      # xmlSchemaCheckCOSSTRestricts
      # Schema Component Constraint: Derivation Valid (Restriction, Simple) (cos-st-restricts)
      # Returns -1 on internal errors, 0 if the type is validly derived, a positive error
      # code otherwise.
      def check_cosst_restricts(pctxt, type)
        if type.type != XML_SCHEMA_TYPE_SIMPLE
          internal_err(pctxt, "xmlSchemaCheckCOSSTRestricts",
            "given type is not a user-derived simpleType")
          return -1
        end

        if wxs_is_atomic(type)
          # 1.1 The {base type definition} must be an atomic simple type definition or a
          # built-in primitive datatype.
          unless wxs_is_atomic(type.base_type)
            p_custom_err(pctxt, ErrCode::SCHEMAP_COS_ST_RESTRICTS_1_1,
              type, nil,
              "The base type '%s' is not an atomic simple type",
              get_component_q_name(type.base_type))
            return ErrCode::SCHEMAP_COS_ST_RESTRICTS_1_1
          end
          # 1.2 The {final} of the {base type definition} must not contain restriction.
          if type_final_contains(type.base_type, XML_SCHEMAS_TYPE_FINAL_RESTRICTION) != 0
            p_custom_err(pctxt, ErrCode::SCHEMAP_COS_ST_RESTRICTS_1_2,
              type, nil,
              "The final of its base type '%s' must not contain 'restriction'",
              get_component_q_name(type.base_type))
            return ErrCode::SCHEMAP_COS_ST_RESTRICTS_1_2
          end

          # 1.3.1 DF must be an allowed constraining facet for the {primitive type
          # definition}, as specified in the appropriate subsection of 3.2 Primitive
          # datatypes.
          unless type.facets.nil?
            ok = true
            primitive = get_primitive_type(type)
            if primitive.nil?
              internal_err(pctxt, "xmlSchemaCheckCOSSTRestricts", "failed to get primitive type")
              return -1
            end
            facet = type.facets
            while facet
              if Types.is_built_in_type_facet(primitive, facet.type) == 0
                ok = false
                p_illegal_facet_atomic_err(pctxt,
                  ErrCode::SCHEMAP_COS_ST_RESTRICTS_1_3_1,
                  type, primitive, facet)
              end
              facet = facet.next
            end
            return ErrCode::SCHEMAP_COS_ST_RESTRICTS_1_3_1 unless ok
          end
          # SPEC (1.3.2) is handled in xmlSchemaDeriveAndValidateFacets()
        elsif wxs_is_list(type)
          item_type = type.subtypes
          if item_type.nil? || !wxs_is_simple(item_type)
            internal_err(pctxt, "xmlSchemaCheckCOSSTRestricts", "failed to evaluate the item type")
            return -1
          end
          type_fixup(item_type, pctxt) if wxs_is_type_not_fixed(item_type)
          # 2.1 The {item type definition} must have a {variety} of atomic or union (in
          # which case all the {member type definitions} must be atomic).
          if !wxs_is_atomic(item_type) && !wxs_is_union(item_type)
            p_custom_err(pctxt, ErrCode::SCHEMAP_COS_ST_RESTRICTS_2_1,
              type, nil,
              "The item type '%s' does not have a variety of atomic or union",
              get_component_q_name(item_type))
            return ErrCode::SCHEMAP_COS_ST_RESTRICTS_2_1
          elsif wxs_is_union(item_type)
            member = item_type.member_types
            while member
              unless wxs_is_atomic(member.type)
                p_custom_err(pctxt, ErrCode::SCHEMAP_COS_ST_RESTRICTS_2_1,
                  type, nil,
                  "The item type is a union type, but the " \
                  "member type '%s' of this item type is not atomic",
                  get_component_q_name(member.type))
                return ErrCode::SCHEMAP_COS_ST_RESTRICTS_2_1
              end
              member = member.next
            end
          end

          if wxs_is_any_simple_type(type.base_type)
            # This is the case if we have: <simpleType><list ..
            # 2.3.1.1 The {final} of the {item type definition} must not contain list.
            if type_final_contains(item_type, XML_SCHEMAS_TYPE_FINAL_LIST) != 0
              p_custom_err(pctxt, ErrCode::SCHEMAP_COS_ST_RESTRICTS_2_3_1_1,
                type, nil,
                "The final of its item type '%s' must not contain 'list'",
                get_component_q_name(item_type))
              return ErrCode::SCHEMAP_COS_ST_RESTRICTS_2_3_1_1
            end
            # 2.3.1.2 The {facets} must only contain the whiteSpace facet component.
            unless type.facets.nil?
              facet = type.facets
              while facet
                if facet.type != XML_SCHEMA_FACET_WHITESPACE
                  p_illegal_facet_list_union_err(pctxt,
                    ErrCode::SCHEMAP_COS_ST_RESTRICTS_2_3_1_2, type, facet)
                  return ErrCode::SCHEMAP_COS_ST_RESTRICTS_2_3_1_2
                end
                facet = facet.next
              end
            end
          else
            # This is the case if we have: <simpleType><restriction ...
            # 2.3.2.1 The {base type definition} must have a {variety} of list.
            unless wxs_is_list(type.base_type)
              p_custom_err(pctxt, ErrCode::SCHEMAP_COS_ST_RESTRICTS_2_3_2_1,
                type, nil,
                "The base type '%s' must be a list type",
                get_component_q_name(type.base_type))
              return ErrCode::SCHEMAP_COS_ST_RESTRICTS_2_3_2_1
            end
            # 2.3.2.2 The {final} of the {base type definition} must not contain restriction.
            if type_final_contains(type.base_type, XML_SCHEMAS_TYPE_FINAL_RESTRICTION) != 0
              p_custom_err(pctxt, ErrCode::SCHEMAP_COS_ST_RESTRICTS_2_3_2_2,
                type, nil,
                "The 'final' of the base type '%s' must not contain 'restriction'",
                get_component_q_name(type.base_type))
              return ErrCode::SCHEMAP_COS_ST_RESTRICTS_2_3_2_2
            end
            # 2.3.2.3 The {item type definition} must be validly derived from the {base type
            # definition}'s {item type definition} given the empty set, as defined in Type
            # Derivation OK (Simple) ($3.14.6).
            base_item_type = type.base_type.subtypes
            if base_item_type.nil? || !wxs_is_simple(base_item_type)
              internal_err(pctxt, "xmlSchemaCheckCOSSTRestricts",
                "failed to eval the item type of a base type")
              return -1
            end
            if !item_type.equal?(base_item_type) &&
                check_cosst_derived_ok(pctxt, item_type, base_item_type, 0) != 0
              p_custom_err_ext(pctxt, ErrCode::SCHEMAP_COS_ST_RESTRICTS_2_3_2_3,
                type, nil,
                "The item type '%s' is not validly derived from " \
                "the item type '%s' of the base type '%s'",
                get_component_q_name(item_type),
                get_component_q_name(base_item_type),
                get_component_q_name(type.base_type))
              return ErrCode::SCHEMAP_COS_ST_RESTRICTS_2_3_2_3
            end

            unless type.facets.nil?
              ok = true
              # 2.3.2.4 Only length, minLength, maxLength, whiteSpace, pattern and
              # enumeration facet components are allowed among the {facets}.
              facet = type.facets
              while facet
                case facet.type
                when XML_SCHEMA_FACET_LENGTH, XML_SCHEMA_FACET_MINLENGTH,
                  XML_SCHEMA_FACET_MAXLENGTH, XML_SCHEMA_FACET_WHITESPACE,
                  XML_SCHEMA_FACET_PATTERN, XML_SCHEMA_FACET_ENUMERATION
                  nil
                else
                  p_illegal_facet_list_union_err(pctxt,
                    ErrCode::SCHEMAP_COS_ST_RESTRICTS_2_3_2_4, type, facet)
                  # We could return, but it's nicer to report all invalid facets.
                  ok = false
                end
                facet = facet.next
              end
              return ErrCode::SCHEMAP_COS_ST_RESTRICTS_2_3_2_4 unless ok
              # SPEC (2.3.2.5) (same as 1.3.2) is done in
              # xmlSchemaDeriveAndValidateFacets()
            end
          end
        elsif wxs_is_union(type)
          # 3.1 The {member type definitions} must all have {variety} of atomic or list.
          member = type.member_types
          while member
            type_fixup(member.type, pctxt) if wxs_is_type_not_fixed(member.type)

            if !wxs_is_atomic(member.type) && !wxs_is_list(member.type)
              p_custom_err(pctxt, ErrCode::SCHEMAP_COS_ST_RESTRICTS_3_1,
                type, nil,
                "The member type '%s' is neither an atomic, nor a list type",
                get_component_q_name(member.type))
              return ErrCode::SCHEMAP_COS_ST_RESTRICTS_3_1
            end
            member = member.next
          end
          # 3.3.1 If the {base type definition} is the `simple ur-type definition`
          if type.base_type.built_in_type == XML_SCHEMAS_ANYSIMPLETYPE
            # 3.3.1.1 All of the {member type definitions} must have a {final} which does
            # not contain union.
            member = type.member_types
            while member
              if type_final_contains(member.type, XML_SCHEMAS_TYPE_FINAL_UNION) != 0
                p_custom_err(pctxt, ErrCode::SCHEMAP_COS_ST_RESTRICTS_3_3_1,
                  type, nil,
                  "The 'final' of member type '%s' contains 'union'",
                  get_component_q_name(member.type))
                return ErrCode::SCHEMAP_COS_ST_RESTRICTS_3_3_1
              end
              member = member.next
            end
            # 3.3.1.2 The {facets} must be empty.
            unless type.facet_set.nil?
              p_custom_err(pctxt, ErrCode::SCHEMAP_COS_ST_RESTRICTS_3_3_1_2,
                type, nil, "No facets allowed", nil)
              return ErrCode::SCHEMAP_COS_ST_RESTRICTS_3_3_1_2
            end
          else
            # 3.3.2.1 The {base type definition} must have a {variety} of union.
            unless wxs_is_union(type.base_type)
              p_custom_err(pctxt, ErrCode::SCHEMAP_COS_ST_RESTRICTS_3_3_2_1,
                type, nil,
                "The base type '%s' is not a union type",
                get_component_q_name(type.base_type))
              return ErrCode::SCHEMAP_COS_ST_RESTRICTS_3_3_2_1
            end
            # 3.3.2.2 The {final} of the {base type definition} must not contain restriction.
            if type_final_contains(type.base_type, XML_SCHEMAS_TYPE_FINAL_RESTRICTION) != 0
              p_custom_err(pctxt, ErrCode::SCHEMAP_COS_ST_RESTRICTS_3_3_2_2,
                type, nil,
                "The 'final' of its base type '%s' must not contain 'restriction'",
                get_component_q_name(type.base_type))
              return ErrCode::SCHEMAP_COS_ST_RESTRICTS_3_3_2_2
            end
            # 3.3.2.3 The {member type definitions}, in order, must be validly derived from
            # the corresponding type definitions in the {base type definition}'s {member type
            # definitions} given the empty set, as defined in Type Derivation OK (Simple).
            unless type.member_types.nil?
              member = type.member_types
              base_member = get_union_simple_type_member_types(type.base_type)
              if member.nil? && !base_member.nil?
                internal_err(pctxt, "xmlSchemaCheckCOSSTRestricts",
                  "different number of member types in base")
              end
              while member
                if base_member.nil?
                  internal_err(pctxt, "xmlSchemaCheckCOSSTRestricts",
                    "different number of member types in base")
                elsif !member.type.equal?(base_member.type) &&
                    check_cosst_derived_ok(pctxt, member.type, base_member.type, 0) != 0
                  p_custom_err_ext(pctxt, ErrCode::SCHEMAP_COS_ST_RESTRICTS_3_3_2_3,
                    type, nil,
                    "The member type %s is not validly " \
                    "derived from its corresponding member " \
                    "type %s of the base type %s",
                    get_component_q_name(member.type),
                    get_component_q_name(base_member.type),
                    get_component_q_name(type.base_type))
                  return ErrCode::SCHEMAP_COS_ST_RESTRICTS_3_3_2_3
                end
                member = member.next
                base_member = base_member.next unless base_member.nil?
              end
            end
            # 3.3.2.4 Only pattern and enumeration facet components are allowed among the
            # {facets}.
            unless type.facets.nil?
              ok = true
              facet = type.facets
              while facet
                if facet.type != XML_SCHEMA_FACET_PATTERN &&
                    facet.type != XML_SCHEMA_FACET_ENUMERATION
                  p_illegal_facet_list_union_err(pctxt,
                    ErrCode::SCHEMAP_COS_ST_RESTRICTS_3_3_2_4, type, facet)
                  ok = false
                end
                facet = facet.next
              end
              return ErrCode::SCHEMAP_COS_ST_RESTRICTS_3_3_2_4 unless ok
            end
            # SPEC (3.3.2.5) (same as 1.3.2) is done in xmlSchemaDeriveAndValidateFacets()
          end
        end
        0
      end

      # xmlSchemaCheckSRCSimpleType (#if 0 in C; a no-op returning 0)
      def check_src_simple_type(ctxt, type)
        0
      end

      # xmlSchemaCreateVCtxtOnPCtxt
      def create_v_ctxt_on_p_ctxt(ctxt)
        if ctxt.vctxt.nil?
          ctxt.vctxt = new_valid_ctxt(nil)
          if ctxt.vctxt.nil?
            p_err(ctxt, nil, ErrCode::SCHEMAP_INTERNAL,
              "Internal error: xmlSchemaCreateVCtxtOnPCtxt, " \
              "failed to create a temp. validation context.\n",
              nil, nil)
            return -1
          end
          # TODO: Pass user data.
          set_valid_errors(ctxt.vctxt, ctxt.error, ctxt.warning, ctxt.err_ctxt)
          set_valid_structured_errors(ctxt.vctxt, ctxt.serror, ctxt.err_ctxt)
        end
        0
      end

      # xmlSchemaParseCheckCOSValidDefault
      # Schema Component Constraint: Element Default Valid (Immediate) (cos-valid-default)
      # This will be used by the parser only. For the validator there's an other version.
      # C: (pctxt, node, type, value, xmlSchemaValPtr *val)  (val may be NULL)
      # Ruby: parse_check_cos_valid_default(pctxt, node, type, value, want_val) -> [ret, val]
      def parse_check_cos_valid_default(pctxt, node, type, value, want_val)
        ret = 0
        val = nil
        # cos-valid-default: For a string to be a valid default with respect to a type
        # definition the appropriate case among the following must be true:
        if wxs_is_complex(type)
          # SPEC (2.1) "its {content type} must be a simple type definition or mixed."
          # SPEC (2.2.2) "If the {content type} is mixed, then the {content type}'s particle
          # must be `emptiable` as defined by Particle Emptiable ($3.9.6)."
          if !wxs_has_simple_content(type) &&
              (!wxs_has_mixed_content(type) || wxs_emptiable(type) == 0)
            # NOTE that this covers (2.2.2) as well.
            p_custom_err(pctxt, ErrCode::SCHEMAP_COS_VALID_DEFAULT_2_1,
              type, type.node,
              "For a string to be a valid default, the type definition " \
              "must be a simple type or a complex type with mixed content " \
              "and a particle emptiable", nil)
            return [ErrCode::SCHEMAP_COS_VALID_DEFAULT_2_1, nil]
          end
        end
        # 1 If the type definition is a simple type definition, then the string must be
        # `valid` with respect to that definition as defined by String Valid ($3.14.4).
        # AND
        # 2.2.1 If the {content type} is a simple type definition, then the string must be
        # `valid` with respect to that simple type definition as defined by String Valid.
        if wxs_is_simple(type)
          ret, val = v_check_cvc_simple_type(pctxt, node, type, value, want_val, 1, 1, 0)
        elsif wxs_has_simple_content(type)
          ret, val = v_check_cvc_simple_type(pctxt, node, type.content_type_def, value,
            want_val, 1, 1, 0)
        else
          return [ret, nil]
        end

        if ret < 0
          internal_err(pctxt, "xmlSchemaParseCheckCOSValidDefault",
            "calling xmlSchemaVCheckCVCSimpleType()")
        end
        [ret, val]
      end

      # xmlSchemaCheckCTPropsCorrect
      # Schema Component Constraint: Complex Type Definition Properties Correct
      # (ct-props-correct)
      # Returns 0 if the constraints are satisfied, a positive error code if not and -1 if an
      # internal error occurred.
      def check_ct_props_correct(pctxt, type)
        # SPEC (1) ...
        if !type.base_type.nil? && wxs_is_simple(type.base_type) && !wxs_is_extension(type)
          # SPEC (2) "If the {base type definition} is a simple type definition, the
          # {derivation method} must be extension."
          custom_err(pctxt, ErrCode::SCHEMAP_SRC_CT_1,
            nil, type,
            "If the base type is a simple type, the derivation method must be " \
            "'extension'", nil, nil)
          return ErrCode::SCHEMAP_SRC_CT_1
        end
        # SPEC (3) is done in xmlSchemaCheckTypeDefCircular().
        # NOTE that (4) and (5) need the following:
        #   - attribute uses need to be already inherited (apply attr. prohibitions)
        #   - attribute group references need to be expanded already
        #   - simple types need to be typefixed already
        if type.attr_uses && type.attr_uses.nb_items > 1
          uses = type.attr_uses
          has_id = false
          i = uses.nb_items - 1
          while i >= 0
            use = uses.items[i]
            removed = false
            # SPEC ct-props-correct (4) "Two distinct attribute declarations in the
            # {attribute uses} must not have identical {name}s and {target namespace}s."
            if i > 0
              j = i - 1
              while j >= 0
                tmp = uses.items[j]
                if use.attr_decl.name == tmp.attr_decl.name &&
                    use.attr_decl.target_namespace == tmp.attr_decl.target_namespace
                  custom_err(pctxt, ErrCode::SCHEMAP_AG_PROPS_CORRECT,
                    nil, type,
                    "Duplicate %s",
                    get_component_designation(use),
                    nil)
                  # Remove the duplicate.
                  uses.items.delete_at(i)

                  removed = true
                  break
                end
                j -= 1
              end
            end
            unless removed
              # SPEC ct-props-correct (5) "Two distinct attribute declarations in the
              # {attribute uses} must not have {type definition}s which are or are derived
              # from ID."
              if !use.attr_decl.subtypes.nil? &&
                  is_derived_from_built_in_type(use.attr_decl.subtypes, XML_SCHEMAS_ID) != 0
                if has_id
                  custom_err(pctxt, ErrCode::SCHEMAP_AG_PROPS_CORRECT,
                    nil, type,
                    "There must not exist more than one attribute " \
                    "declaration of type 'xs:ID' " \
                    "(or derived from 'xs:ID'). The %s violates this " \
                    "constraint",
                    get_component_designation(use),
                    nil)
                  uses.items.delete_at(i)
                end
                has_id = true
              end
            end
            i -= 1
          end
        end
        0
      end

      # xmlSchemaAreEqualTypes
      def are_equal_types(type_a, type_b)
        return 0 if type_a.nil? || type_b.nil?

        type_a.equal?(type_b) ? 1 : 0
      end

      # xmlSchemaCheckCOSCTDerivedOK
      # Schema Component Constraint: Type Derivation OK (Complex) (cos-ct-derived-ok)
      # Returns 0 if the constraints are satisfied, or 1 if not.
      def check_cosct_derived_ok(actxt, type, base_type, set)
        equal = are_equal_types(type, base_type)
        if equal == 0
          # SPEC (1) "If B and D are not the same type definition, then the {derivation
          # method} of D must not be in the subset."
          if ((set & SUBSET_EXTENSION) != 0 && wxs_is_extension(type)) ||
              ((set & SUBSET_RESTRICTION) != 0 && wxs_is_restriction(type))
            return 1
          end
        else
          # SPEC (2.1) "B and D must be the same type definition."
          return 0
        end
        # SPEC (2.2) "B must be D's {base type definition}."
        return 0 if type.base_type.equal?(base_type)
        # SPEC (2.3.1) "D's {base type definition} must not be the `ur-type definition`."
        return 1 if wxs_is_anytype(type.base_type)

        if wxs_is_complex(type.base_type)
          # SPEC (2.3.2.1) "If D's {base type definition} is complex, then it must be validly
          # derived from B given the subset as defined by this constraint."
          check_cosct_derived_ok(actxt, type.base_type, base_type, set)
        else
          # SPEC (2.3.2.2) "If D's {base type definition} is simple, then it must be validly
          # derived from B given the subset as defined in Type Derivation OK (Simple).
          check_cosst_derived_ok(actxt, type.base_type, base_type, set)
        end
      end

      # xmlSchemaCheckCOSDerivedOK
      # Calls: Type Derivation OK (Simple) AND Type Derivation OK (Complex)
      # Returns 0 on success, an positive error code otherwise.
      def check_cos_derived_ok(actxt, type, base_type, set)
        if wxs_is_simple(type)
          check_cosst_derived_ok(actxt, type, base_type, set)
        else
          check_cosct_derived_ok(actxt, type, base_type, set)
        end
      end

      # xmlSchemaCheckCOSCTExtends
      # Schema Component Constraint: Derivation Valid (Extension) (cos-ct-extends)
      # Returns 0 if the constraints are satisfied, a positive error code if not and -1 if an
      # internal error occurred.
      def check_cosct_extends(ctxt, type)
        base = type.base_type
        # SPEC (1) "If the {base type definition} is a complex type definition, then all of
        # the following must be true:"
        if wxs_is_complex(base)
          # SPEC (1.1) "The {final} of the {base type definition} must not contain extension."
          if (base.flags & XML_SCHEMAS_TYPE_FINAL_EXTENSION) != 0
            p_custom_err(ctxt, ErrCode::SCHEMAP_COS_CT_EXTENDS_1_1,
              type, nil,
              "The 'final' of the base type definition " \
              "contains 'extension'", nil)
            return ErrCode::SCHEMAP_COS_CT_EXTENDS_1_1
          end
          # (1.2) and (1.3) are not applied (#if 0 in C).
          # SPEC (1.4) "One of the following must be true:"
          if !type.content_type_def.nil? && type.content_type_def.equal?(base.content_type_def)
            # SPEC (1.4.1) PASS
          elsif type.content_type == XML_SCHEMA_CONTENT_EMPTY &&
              base.content_type == XML_SCHEMA_CONTENT_EMPTY
            # SPEC (1.4.2) PASS
          else
            # SPEC (1.4.3) "All of the following must be true:"
            if type.subtypes.nil?
              # SPEC 1.4.3.1 The {content type} of the complex type definition itself must
              # specify a particle.
              p_custom_err(ctxt, ErrCode::SCHEMAP_COS_CT_EXTENDS_1_1,
                type, nil,
                "The content type must specify a particle", nil)
              return ErrCode::SCHEMAP_COS_CT_EXTENDS_1_1
            end
            # SPEC (1.4.3.2) "One of the following must be true:"
            if base.content_type == XML_SCHEMA_CONTENT_EMPTY
              # SPEC (1.4.3.2.1) PASS
            elsif type.content_type != base.content_type ||
                (type.content_type != XML_SCHEMA_CONTENT_MIXED &&
                 type.content_type != XML_SCHEMA_CONTENT_ELEMENTS)
              # SPEC (1.4.3.2.2.1) "Both {content type}s must be mixed or both must be
              # element-only."
              p_custom_err(ctxt, ErrCode::SCHEMAP_COS_CT_EXTENDS_1_1,
                type, nil,
                "The content type of both, the type and its base " \
                "type, must either 'mixed' or 'element-only'", nil)
              return ErrCode::SCHEMAP_COS_CT_EXTENDS_1_1
            end
            # URGENT TODO SPEC (1.4.3.2.2.2) / (1.5) not checked.
          end
        else
          # SPEC (2) "If the {base type definition} is a simple type definition, then all of
          # the following must be true:"
          unless type.content_type_def.equal?(base)
            # SPEC (2.1) "The {content type} must be the same simple type definition."
            p_custom_err(ctxt, ErrCode::SCHEMAP_COS_CT_EXTENDS_1_1,
              type, nil,
              "The content type must be the simple base type", nil)
            return ErrCode::SCHEMAP_COS_CT_EXTENDS_1_1
          end
          if (base.flags & XML_SCHEMAS_TYPE_FINAL_EXTENSION) != 0
            # SPEC (2.2) "The {final} of the {base type definition} must not contain
            # extension" NOTE that this is the same as (1.1).
            p_custom_err(ctxt, ErrCode::SCHEMAP_COS_CT_EXTENDS_1_1,
              type, nil,
              "The 'final' of the base type definition " \
              "contains 'extension'", nil)
            return ErrCode::SCHEMAP_COS_CT_EXTENDS_1_1
          end
        end
        0
      end

      # xmlSchemaCheckDerivationOKRestriction
      # Schema Component Constraint: Derivation Valid (Restriction, Complex)
      # (derivation-ok-restriction)
      # Returns 0 if the constraints are satisfied, a positive error code if not and -1 if an
      # internal error occurred.
      def check_derivation_ok_restriction(ctxt, type)
        base = type.base_type
        unless wxs_is_complex(base)
          custom_err(ctxt, ErrCode::SCHEMAP_DERIVATION_OK_RESTRICTION_1,
            type.node, type,
            "The base type must be a complex type", nil, nil)
          return ctxt.err
        end
        if (base.flags & XML_SCHEMAS_TYPE_FINAL_RESTRICTION) != 0
          # SPEC (1) "The {base type definition} must be a complex type definition whose
          # {final} does not contain restriction."
          custom_err(ctxt, ErrCode::SCHEMAP_DERIVATION_OK_RESTRICTION_1,
            type.node, type,
            "The 'final' of the base type definition " \
            "contains 'restriction'", nil, nil)
          return ctxt.err
        end
        # SPEC (2), (3) and (4)
        if check_derivation_ok_restriction2to4(ctxt, XML_SCHEMA_ACTION_DERIVE,
          type, base, type.attr_uses, base.attr_uses,
          type.attribute_wildcard, base.attribute_wildcard) == -1
          return -1
        end
        # SPEC (5) "One of the following must be true:"
        if base.built_in_type == XML_SCHEMAS_ANYTYPE
          # SPEC (5.1) PASS
        elsif type.content_type == XML_SCHEMA_CONTENT_SIMPLE ||
            type.content_type == XML_SCHEMA_CONTENT_BASIC
          # SPEC (5.2.1) "The {content type} of the complex type definition must be a simple
          # type definition"
          # SPEC (5.2.2) "One of the following must be true:"
          if base.content_type == XML_SCHEMA_CONTENT_SIMPLE ||
              base.content_type == XML_SCHEMA_CONTENT_BASIC
            # SPEC (5.2.2.1) "The {content type} of the {base type definition} must be a
            # simple type definition from which the {content type} is validly derived given
            # the empty set as defined in Type Derivation OK (Simple) ($3.14.6)."
            err = check_cosst_derived_ok(ctxt, type.content_type_def, base.content_type_def, 0)
            if err != 0
              return -1 if err == -1

              custom_err(ctxt, ErrCode::SCHEMAP_DERIVATION_OK_RESTRICTION_1,
                nil, type,
                "The {content type} %s is not validly derived from the " \
                "base type's {content type} %s",
                get_component_designation(type.content_type_def),
                get_component_designation(base.content_type_def))
              return ctxt.err
            end
          elsif base.content_type == XML_SCHEMA_CONTENT_MIXED &&
              is_particle_emptiable(base.subtypes) != 0
            # SPEC (5.2.2.2) PASS
          else
            p_custom_err(ctxt, ErrCode::SCHEMAP_DERIVATION_OK_RESTRICTION_1,
              type, nil,
              "The content type of the base type must be either " \
              "a simple type or 'mixed' and an emptiable particle", nil)
            return ctxt.err
          end
        elsif type.content_type == XML_SCHEMA_CONTENT_EMPTY
          # SPEC (5.3.1) "The {content type} of the complex type itself must be empty"
          if base.content_type == XML_SCHEMA_CONTENT_EMPTY
            # SPEC (5.3.2.1) PASS
          elsif (base.content_type == XML_SCHEMA_CONTENT_ELEMENTS ||
              base.content_type == XML_SCHEMA_CONTENT_MIXED) &&
              is_particle_emptiable(base.subtypes) != 0
            # SPEC (5.3.2.2) PASS
          else
            p_custom_err(ctxt, ErrCode::SCHEMAP_DERIVATION_OK_RESTRICTION_1,
              type, nil,
              "The content type of the base type must be either " \
              "empty or 'mixed' (or 'elements-only') and an emptiable " \
              "particle", nil)
            return ctxt.err
          end
        elsif type.content_type == XML_SCHEMA_CONTENT_ELEMENTS || wxs_has_mixed_content(type)
          # SPEC (5.4.1.1) "The {content type} of the complex type definition itself must be
          # element-only"
          if wxs_has_mixed_content(type) && !wxs_has_mixed_content(base)
            # SPEC (5.4.1.2) "The {content type} of the complex type definition itself and
            # of the {base type definition} must be mixed"
            p_custom_err(ctxt, ErrCode::SCHEMAP_DERIVATION_OK_RESTRICTION_1,
              type, nil,
              "If the content type is 'mixed', then the content type of the " \
              "base type must also be 'mixed'", nil)
            return ctxt.err
          end
          # SPEC (5.4.2) URGENT TODO
        else
          p_custom_err(ctxt, ErrCode::SCHEMAP_DERIVATION_OK_RESTRICTION_1,
            type, nil,
            "The type is not a valid restriction of its base type", nil)
          return ctxt.err
        end
        0
      end

      # xmlSchemaCheckCTComponent
      # Returns 0 if the constraints are satisfied, a positive error code if not and -1 if an
      # internal error occurred.
      def check_ct_component(ctxt, type)
        # Complex Type Definition Properties Correct
        ret = check_ct_props_correct(ctxt, type)
        return ret if ret != 0

        if wxs_is_extension(type)
          check_cosct_extends(ctxt, type)
        else
          check_derivation_ok_restriction(ctxt, type)
        end
      end

      # xmlSchemaCheckSRCCT
      # Schema Representation Constraint: Complex Type Definition Representation OK (src-ct)
      # Returns 0 if the constraints are satisfied, a positive error code if not and -1 if an
      # internal error occurred.
      def check_srcct(ctxt, type)
        ret = 0
        base = type.base_type
        if !wxs_has_simple_content(type)
          # 1 If the <complexContent> alternative is chosen, the type definition `resolved`
          # to by the `actual value` of the base [attribute] must be a complex type
          # definition;
          unless wxs_is_complex(base)
            p_custom_err(ctxt, ErrCode::SCHEMAP_SRC_CT_1,
              type, type.node,
              "If using <complexContent>, the base type is expected to be " \
              "a complex type. The base type '%s' is a simple type",
              format_q_name(base.target_namespace, base.name))
            return ErrCode::SCHEMAP_SRC_CT_1
          end
        else
          # SPEC 2 If the <simpleContent> alternative is chosen, all of the following must
          # be true:
          # 2.1 The type definition `resolved` to by the `actual value` of the base
          # [attribute] must be one of the following:
          if wxs_is_simple(base)
            unless wxs_is_extension(type)
              # 2.1.3 only if the <extension> alternative is also chosen, a simple type
              # definition.
              p_custom_err(ctxt, ErrCode::SCHEMAP_SRC_CT_1,
                type, nil,
                "If using <simpleContent> and <restriction>, the base " \
                "type must be a complex type. The base type '%s' is " \
                "a simple type",
                format_q_name(base.target_namespace, base.name))
              return ErrCode::SCHEMAP_SRC_CT_1
            end
          else
            # Base type is a complex type.
            if base.content_type == XML_SCHEMA_CONTENT_SIMPLE ||
                base.content_type == XML_SCHEMA_CONTENT_BASIC
              # 2.1.1 a complex type definition whose {content type} is a simple type
              # definition; PASS
              if base.content_type_def.nil?
                p_custom_err(ctxt, ErrCode::SCHEMAP_INTERNAL,
                  type, nil,
                  "Internal error: xmlSchemaCheckSRCCT, " \
                  "'%s', base type has no content type",
                  type.name)
                return -1
              end
            elsif base.content_type == XML_SCHEMA_CONTENT_MIXED && wxs_is_restriction(type)
              # 2.1.2 only if the <restriction> alternative is also chosen, a complex type
              # definition whose {content type} is mixed and a particle emptiable.
              if is_particle_emptiable(base.subtypes) == 0
                ret = ErrCode::SCHEMAP_SRC_CT_1
              elsif type.content_type_def.nil?
                # Attention: at this point the <simpleType> child is in ->contentTypeDef
                # (put there during parsing).
                # 2.2 If clause 2.1.2 above is satisfied, then there must be a <simpleType>
                # among the [children] of <restriction>.
                p_custom_err(ctxt, ErrCode::SCHEMAP_SRC_CT_1,
                  type, nil,
                  "A <simpleType> is expected among the children " \
                  "of <restriction>, if <simpleContent> is used and " \
                  "the base type '%s' is a complex type",
                  format_q_name(base.target_namespace, base.name))
                return ErrCode::SCHEMAP_SRC_CT_1
              end
            else
              ret = ErrCode::SCHEMAP_SRC_CT_1
            end
          end
          if ret > 0
            if wxs_is_restriction(type)
              p_custom_err(ctxt, ErrCode::SCHEMAP_SRC_CT_1,
                type, nil,
                "If <simpleContent> and <restriction> is used, the " \
                "base type must be a simple type or a complex type with " \
                "mixed content and particle emptiable. The base type " \
                "'%s' is none of those",
                format_q_name(base.target_namespace, base.name))
            else
              p_custom_err(ctxt, ErrCode::SCHEMAP_SRC_CT_1,
                type, nil,
                "If <simpleContent> and <extension> is used, the " \
                "base type must be a simple type. The base type '%s' " \
                "is a complex type",
                format_q_name(base.target_namespace, base.name))
            end
          end
        end
        # SPEC (3) will be done in xmlSchemaTypeFixup().
        # SPEC (4) is done in xmlSchemaFixupTypeAttributeUses().
        ret
      end
    end
  end
end
