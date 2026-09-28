# frozen_string_literal: true

require_relative "structs"
require_relative "macros"
require_relative "common"

# Port of xmlschemas.c (2.13.9) lines ~13155-15160: reference resolution helpers, type helpers,
# wildcard algebra, attribute-use derivation checks, particle emptiability, cos-st-derived-OK,
# circularity of type definitions.
#
# Note on string comparison: the C code compares dict-interned strings by pointer; here that
# is String#== (nil == nil is true, like NULL == NULL).
module Nokogiri
  module Pure
    module Schemas
      extend self

      XML_SCHEMA_ACTION_DERIVE = 0
      XML_SCHEMA_ACTION_REDEFINE = 1

      # WXS_ACTION_STR(a)
      def wxs_action_str(a) = a == XML_SCHEMA_ACTION_DERIVE ? "base" : "redefined"

      # xmlSchemaResolveElementReferences
      # Resolves the references of an element declaration or particle, which has an element
      # declaration as it's term.
      def resolve_element_references(elem_decl, ctxt)
        return if ctxt.nil? || elem_decl.nil? ||
          (elem_decl.flags & XML_SCHEMAS_ELEM_INTERNAL_RESOLVED) != 0

        elem_decl.flags |= XML_SCHEMAS_ELEM_INTERNAL_RESOLVED

        if elem_decl.subtypes.nil? && !elem_decl.named_type.nil?
          # (type definition) ... otherwise the type definition `resolved` to by the
          # `actual value` of the type [attribute] ...
          type = get_type(ctxt.schema, elem_decl.named_type, elem_decl.named_type_ns)
          if type.nil?
            p_res_comp_attr_err(ctxt, ErrCode::SCHEMAP_SRC_RESOLVE,
              elem_decl, elem_decl.node,
              "type", elem_decl.named_type, elem_decl.named_type_ns,
              XML_SCHEMA_TYPE_BASIC, "type definition")
          else
            elem_decl.subtypes = type
          end
        end
        unless elem_decl.subst_group.nil?
          subst_head = get_elem(ctxt.schema, elem_decl.subst_group, elem_decl.subst_group_ns)
          if subst_head.nil?
            p_res_comp_attr_err(ctxt, ErrCode::SCHEMAP_SRC_RESOLVE,
              elem_decl, nil,
              "substitutionGroup", elem_decl.subst_group,
              elem_decl.subst_group_ns, XML_SCHEMA_TYPE_ELEMENT, nil)
          else
            resolve_element_references(subst_head, ctxt)
            # Set the "substitution group affiliation" (refDecl field).
            elem_decl.ref_decl = subst_head
            # The type definitions is set to: SPEC "...the {type definition} of the element
            # declaration `resolved` to by the `actual value` of the substitutionGroup
            # [attribute], if present"
            if elem_decl.subtypes.nil?
              elem_decl.subtypes = if subst_head.subtypes.nil?
                # This can happen with self-referencing substitution groups. The cycle will
                # be detected later, but we have to set subtypes.
                Types.get_built_in_type(XML_SCHEMAS_ANYTYPE)
              else
                subst_head.subtypes
              end
            end
          end
        end
        # SPEC "The definition of anyType serves as the default type definition for element
        # declarations whose XML representation does not specify one."
        if elem_decl.subtypes.nil? && elem_decl.named_type.nil? && elem_decl.subst_group.nil?
          elem_decl.subtypes = Types.get_built_in_type(XML_SCHEMAS_ANYTYPE)
        end
      end

      # xmlSchemaResolveUnionMemberTypes
      # Checks and builds the "member type definitions" property of the union simple type
      # (part (1); part (2) is done in xmlSchemaFinishMemberTypeDefinitionsProperty()).
      # Returns -1 in case of an internal error, 0 otherwise.
      def resolve_union_member_types(ctxt, type)
        # Resolve references.
        link = type.member_types
        last_link = nil
        while link
          name = link.type.name
          ns_name = link.type.target_namespace

          member_type = get_type(ctxt.schema, name, ns_name)
          if member_type.nil? || !wxs_is_simple(member_type)
            p_res_comp_attr_err(ctxt, ErrCode::SCHEMAP_SRC_RESOLVE,
              type, type.node, "memberTypes",
              name, ns_name, XML_SCHEMA_TYPE_SIMPLE, nil)
            # Remove the member type link.
            if last_link.nil?
              type.member_types = link.next
            else
              last_link.next = link.next
            end
            link = link.next
          else
            link.type = member_type
            last_link = link
            link = link.next
          end
        end
        # Add local simple types,
        member_type = type.subtypes
        while member_type
          link = SchemaTypeLink.new(type: member_type, next: nil)
          if last_link.nil?
            type.member_types = link
          else
            last_link.next = link
          end
          last_link = link
          member_type = member_type.next
        end
        0
      end

      # xmlSchemaIsDerivedFromBuiltInType
      # Returns 1 if the type has the given value type, or is derived from such a type.
      def is_derived_from_built_in_type(type, val_type)
        while true
          return 0 if type.nil?
          return 0 if wxs_is_complex(type)

          if type.type == XML_SCHEMA_TYPE_BASIC
            return 1 if type.built_in_type == val_type
            return 0 if type.built_in_type == XML_SCHEMAS_ANYSIMPLETYPE ||
              type.built_in_type == XML_SCHEMAS_ANYTYPE
          end
          type = type.subtypes
        end
      end

      # xmlSchemaIsUserDerivedFromBuiltInType (#if 0 in C; kept for completeness)
      def is_user_derived_from_built_in_type(type, val_type)
        return 0 if type.nil?
        return 0 if wxs_is_complex(type)

        if type.type == XML_SCHEMA_TYPE_BASIC
          return 1 if type.built_in_type == val_type

          0
        else
          is_derived_from_built_in_type(type.subtypes, val_type)
        end
      end

      # xmlSchemaQueryBuiltInType (#if 0 in C; kept for completeness)
      def query_built_in_type(type)
        return nil if type.nil?
        return nil if wxs_is_complex(type)
        return type if type.type == XML_SCHEMA_TYPE_BASIC

        query_built_in_type(type.subtypes)
      end

      # xmlSchemaGetPrimitiveType
      # Returns the primitive type of the given type or NULL in case of error.
      def get_primitive_type(type)
        while type
          # Note that anySimpleType is actually not a primitive type but we need that here.
          if type.built_in_type == XML_SCHEMAS_ANYSIMPLETYPE ||
              (type.flags & XML_SCHEMAS_TYPE_BUILTIN_PRIMITIVE) != 0
            return type
          end
          type = type.base_type
        end
        nil
      end

      # xmlSchemaGetBuiltInTypeAncestor (#if 0 in C; kept for completeness)
      def get_built_in_type_ancestor(type)
        return nil if wxs_is_list(type) || wxs_is_union(type)

        while type
          return type if type.type == XML_SCHEMA_TYPE_BASIC

          type = type.base_type
        end
        nil
      end

      # xmlSchemaCloneWildcardNsConstraints
      # Clones the namespace constraints of source and assigns them to dest.
      # Returns -1 on internal error, 0 otherwise.
      def clone_wildcard_ns_constraints(ctxt, dest, source)
        return -1 if source.nil? || dest.nil?

        dest.any = source.any
        cur = source.ns_set
        last = nil
        while cur
          tmp = SchemaWildcardNs.new(value: cur.value)
          if last.nil?
            dest.ns_set = tmp
          else
            last.next = tmp
          end
          last = tmp
          cur = cur.next
        end
        dest.neg_ns_set = if !source.neg_ns_set.nil?
          SchemaWildcardNs.new(value: source.neg_ns_set.value)
        end
        0
      end

      # helper: "Check equality of sets" block shared by union/intersection step 1
      def wildcards_same_value?(complete_wild, cur_wild)
        if complete_wild.any == cur_wild.any &&
            complete_wild.ns_set.nil? == cur_wild.ns_set.nil? &&
            complete_wild.neg_ns_set.nil? == cur_wild.neg_ns_set.nil?
          if complete_wild.neg_ns_set.nil? ||
              complete_wild.neg_ns_set.value == cur_wild.neg_ns_set.value
            if !complete_wild.ns_set.nil?
              found = false
              # Check equality of sets.
              cur = complete_wild.ns_set
              while cur
                found = false
                cur_b = cur_wild.ns_set
                while cur_b
                  if cur.value == cur_b.value
                    found = true
                    break
                  end
                  cur_b = cur_b.next
                end
                break unless found

                cur = cur.next
              end
              return true if found
            else
              return true
            end
          end
        end
        false
      end
      private :wildcards_same_value?

      # xmlSchemaUnionWildcards
      # Unions the namespace constraints of the given wildcards. completeWild will hold the
      # resulting union. Returns a positive error code on failure, -1 in case of an internal
      # error, 0 otherwise.
      def union_wildcards(ctxt, complete_wild, cur_wild)
        # 1 If O1 and O2 are the same value, then that value must be the value.
        return 0 if wildcards_same_value?(complete_wild, cur_wild)

        # 2 If either O1 or O2 is any, then any must be the value
        if complete_wild.any != cur_wild.any
          if complete_wild.any == 0
            complete_wild.any = 1
            complete_wild.ns_set = nil
            complete_wild.neg_ns_set = nil
          end
          return 0
        end
        # 3 If both O1 and O2 are sets of (namespace names or `absent`), then the union of
        # those sets must be the value.
        if !complete_wild.ns_set.nil? && !cur_wild.ns_set.nil?
          cur = cur_wild.ns_set
          start = complete_wild.ns_set
          while cur
            found = false
            cur_b = start
            while cur_b
              if cur.value == cur_b.value
                found = true
                break
              end
              cur_b = cur_b.next
            end
            unless found
              tmp = SchemaWildcardNs.new(value: cur.value)
              tmp.next = complete_wild.ns_set
              complete_wild.ns_set = tmp
            end
            cur = cur.next
          end
          return 0
        end
        # 4 If the two are negations of different values (namespace names or `absent`), then
        # a pair of not and `absent` must be the value.
        if !complete_wild.neg_ns_set.nil? && !cur_wild.neg_ns_set.nil? &&
            complete_wild.neg_ns_set.value != cur_wild.neg_ns_set.value
          complete_wild.neg_ns_set.value = nil
          return 0
        end
        # 5.
        if (!complete_wild.neg_ns_set.nil? && !complete_wild.neg_ns_set.value.nil? &&
            !cur_wild.ns_set.nil?) ||
            (!cur_wild.neg_ns_set.nil? && !cur_wild.neg_ns_set.value.nil? &&
            !complete_wild.ns_set.nil?)
          absent_found = false
          if !complete_wild.ns_set.nil?
            cur = complete_wild.ns_set
            cur_b = cur_wild.neg_ns_set
          else
            cur = cur_wild.ns_set
            cur_b = complete_wild.neg_ns_set
          end
          ns_found = false
          while cur
            if cur.value.nil?
              absent_found = true
            elsif cur.value == cur_b.value
              ns_found = true
            end
            break if ns_found && absent_found

            cur = cur.next
          end

          if ns_found && absent_found
            # 5.1 If the set S includes both the negated namespace name and `absent`, then
            # any must be the value.
            complete_wild.any = 1
            complete_wild.ns_set = nil
            complete_wild.neg_ns_set = nil
          elsif ns_found && !absent_found
            # 5.2 If the set S includes the negated namespace name but not `absent`, then a
            # pair of not and `absent` must be the value.
            complete_wild.ns_set = nil
            complete_wild.neg_ns_set = SchemaWildcardNs.new if complete_wild.neg_ns_set.nil?
            complete_wild.neg_ns_set.value = nil
          elsif !ns_found && absent_found
            # 5.3 If the set S includes `absent` but not the negated namespace name, then the
            # union is not expressible.
            p_err(ctxt, complete_wild.node,
              ErrCode::SCHEMAP_UNION_NOT_EXPRESSIBLE,
              "The union of the wildcard is not expressible.\n",
              nil, nil)
            return ErrCode::SCHEMAP_UNION_NOT_EXPRESSIBLE
          elsif !ns_found && !absent_found
            # 5.4 If the set S does not include either the negated namespace name or
            # `absent`, then whichever of O1 or O2 is a pair of not and a namespace name
            # must be the value.
            if complete_wild.neg_ns_set.nil?
              complete_wild.ns_set = nil
              complete_wild.neg_ns_set = SchemaWildcardNs.new(value: cur_wild.neg_ns_set.value)
            end
          end
          return 0
        end
        # 6.
        if (!complete_wild.neg_ns_set.nil? && complete_wild.neg_ns_set.value.nil? &&
            !cur_wild.ns_set.nil?) ||
            (!cur_wild.neg_ns_set.nil? && cur_wild.neg_ns_set.value.nil? &&
            !complete_wild.ns_set.nil?)
          cur = !complete_wild.ns_set.nil? ? complete_wild.ns_set : cur_wild.ns_set
          while cur
            if cur.value.nil?
              # 6.1 If the set S includes `absent`, then any must be the value.
              complete_wild.any = 1
              complete_wild.ns_set = nil
              complete_wild.neg_ns_set = nil
              return 0
            end
            cur = cur.next
          end
          if complete_wild.neg_ns_set.nil?
            # 6.2 If the set S does not include `absent`, then a pair of not and `absent`
            # must be the value.
            complete_wild.ns_set = nil
            complete_wild.neg_ns_set = SchemaWildcardNs.new(value: nil)
          end
          return 0
        end
        0
      end

      # xmlSchemaIntersectWildcards
      # Intersects the namespace constraints of the given wildcards. completeWild will hold
      # the resulting intersection. Returns a positive error code on failure, -1 in case of an
      # internal error, 0 otherwise.
      def intersect_wildcards(ctxt, complete_wild, cur_wild)
        # 1 If O1 and O2 are the same value, then that value must be the value.
        return 0 if wildcards_same_value?(complete_wild, cur_wild)

        # 2 If either O1 or O2 is any, then the other must be the value.
        if complete_wild.any != cur_wild.any && complete_wild.any != 0
          return -1 if clone_wildcard_ns_constraints(ctxt, complete_wild, cur_wild) == -1

          return 0
        end
        # 3 If either O1 or O2 is a pair of not and a value (a namespace name or `absent`)
        # and the other is a set of (namespace names or `absent`), then that set, minus the
        # negated value if it was in the set, minus `absent` if it was in the set, must be
        # the value.
        if (!complete_wild.neg_ns_set.nil? && !cur_wild.ns_set.nil?) ||
            (!cur_wild.neg_ns_set.nil? && !complete_wild.ns_set.nil?)
          if complete_wild.ns_set.nil?
            neg = complete_wild.neg_ns_set.value
            return -1 if clone_wildcard_ns_constraints(ctxt, complete_wild, cur_wild) == -1
          else
            neg = cur_wild.neg_ns_set.value
          end
          # Remove absent and negated.
          prev = nil
          cur = complete_wild.ns_set
          while cur
            if cur.value.nil?
              if prev.nil?
                complete_wild.ns_set = cur.next
              else
                prev.next = cur.next
              end
              break
            end
            prev = cur
            cur = cur.next
          end
          unless neg.nil?
            prev = nil
            cur = complete_wild.ns_set
            while cur
              if cur.value == neg
                if prev.nil?
                  complete_wild.ns_set = cur.next
                else
                  prev.next = cur.next
                end
                break
              end
              prev = cur
              cur = cur.next
            end
          end
          return 0
        end
        # 4 If both O1 and O2 are sets of (namespace names or `absent`), then the
        # intersection of those sets must be the value.
        if !complete_wild.ns_set.nil? && !cur_wild.ns_set.nil?
          cur = complete_wild.ns_set
          prev = nil
          while cur
            found = false
            cur_b = cur_wild.ns_set
            while cur_b
              if cur.value == cur_b.value
                found = true
                break
              end
              cur_b = cur_b.next
            end
            unless found
              if prev.nil?
                complete_wild.ns_set = cur.next
              else
                prev.next = cur.next
              end
              cur = cur.next
              next
            end
            prev = cur
            cur = cur.next
          end
          return 0
        end
        # 5 If the two are negations of different namespace names, then the intersection is
        # not expressible
        if !complete_wild.neg_ns_set.nil? && !cur_wild.neg_ns_set.nil? &&
            complete_wild.neg_ns_set.value != cur_wild.neg_ns_set.value &&
            !complete_wild.neg_ns_set.value.nil? && !cur_wild.neg_ns_set.value.nil?
          p_err(ctxt, complete_wild.node, ErrCode::SCHEMAP_INTERSECTION_NOT_EXPRESSIBLE,
            "The intersection of the wildcard is not expressible.\n",
            nil, nil)
          return ErrCode::SCHEMAP_INTERSECTION_NOT_EXPRESSIBLE
        end
        # 6 If the one is a negation of a namespace name and the other is a negation of
        # `absent`, then the one which is the negation of a namespace name must be the value.
        if !complete_wild.neg_ns_set.nil? && !cur_wild.neg_ns_set.nil? &&
            complete_wild.neg_ns_set.value != cur_wild.neg_ns_set.value &&
            complete_wild.neg_ns_set.value.nil?
          complete_wild.neg_ns_set.value = cur_wild.neg_ns_set.value
        end
        0
      end

      # xmlSchemaCheckCOSNSSubset
      # Schema Component Constraint: Wildcard Subset (cos-ns-subset)
      # Returns 0 if the namespace constraint of sub is an intensional subset of super,
      # 1 otherwise.
      def check_cosns_subset(sub, super_)
        # 1 super must be any.
        return 0 if super_.any != 0
        # 2.1 sub must be a pair of not and a namespace name or `absent`.
        # 2.2 super must be a pair of not and the same value.
        if !sub.neg_ns_set.nil? && !super_.neg_ns_set.nil? &&
            sub.neg_ns_set.value == super_.neg_ns_set.value
          return 0
        end
        # 3.1 sub must be a set whose members are either namespace names or `absent`.
        unless sub.ns_set.nil?
          # 3.2.1 super must be the same set or a superset thereof.
          if !super_.ns_set.nil?
            found = false
            cur = sub.ns_set
            while cur
              found = false
              cur_b = super_.ns_set
              while cur_b
                if cur.value == cur_b.value
                  found = true
                  break
                end
                cur_b = cur_b.next
              end
              return 1 unless found

              cur = cur.next
            end
            return 0 if found
          elsif !super_.neg_ns_set.nil?
            # 3.2.2 super must be a pair of not and a namespace name or `absent` and that
            # value must not be in sub's set.
            cur = sub.ns_set
            while cur
              return 1 if cur.value == super_.neg_ns_set.value

              cur = cur.next
            end
            return 0
          end
        end
        1
      end

      # xmlSchemaGetEffectiveValueConstraint
      # C: (attruse, int *fixed, const xmlChar **value, xmlSchemaValPtr *val)
      # Ruby: returns [ret, fixed, value, val]
      def get_effective_value_constraint(attruse)
        if !attruse.def_value.nil?
          fixed = (attruse.flags & XML_SCHEMA_ATTR_USE_FIXED) != 0 ? 1 : 0
          return [1, fixed, attruse.def_value, attruse.def_val]
        elsif !attruse.attr_decl.nil? && !attruse.attr_decl.def_value.nil?
          fixed = (attruse.attr_decl.flags & XML_SCHEMAS_ATTR_FIXED) != 0 ? 1 : 0
          return [1, fixed, attruse.attr_decl.def_value, attruse.attr_decl.def_val]
        end
        [0, 0, nil, nil]
      end

      # xmlSchemaCheckCVCWildcardNamespace
      # Validation Rule: Wildcard allows Namespace Name (cvc-wildcard-namespace)
      # Returns 0 if the given namespace matches the wildcard, 1 otherwise and -1 on API
      # errors.
      def check_cvc_wildcard_namespace(wild, ns)
        return -1 if wild.nil?
        return 0 if wild.any != 0

        if !wild.ns_set.nil?
          cur = wild.ns_set
          while cur
            return 0 if cur.value == ns

            cur = cur.next
          end
        elsif !wild.neg_ns_set.nil? && !ns.nil? && wild.neg_ns_set.value != ns
          return 0
        end
        1
      end

      # xmlSchemaCheckDerivationOKRestriction2to4
      # Schema Component Constraint: Derivation Valid (Restriction, Complex)
      # derivation-ok-restriction (2) - (4)
      def check_derivation_ok_restriction2to4(pctxt, action, item, base_item, uses, base_uses,
        wild, base_wild)
        cur = nil
        if uses
          uses.items.each do |c|
            cur = c
            found = false
            if base_uses
              base_uses.items.each do |bcur|
                next unless cur.attr_decl.name == bcur.attr_decl.name &&
                  cur.attr_decl.target_namespace == bcur.attr_decl.target_namespace

                # (2.1) "If there is an attribute use in the {attribute uses} of the {base
                # type definition} (call this B) whose {attribute declaration} has the same
                # {name} and {target namespace}, then all of the following must be true:"
                found = true

                if cur.occurs == XML_SCHEMAS_ATTR_USE_OPTIONAL &&
                    bcur.occurs == XML_SCHEMAS_ATTR_USE_REQUIRED
                  # (2.1.1) "one of the following must be true:"
                  # (2.1.1.1) "B's {required} is false."
                  # (2.1.1.2) "R's {required} is true."
                  p_attr_use_err4(pctxt,
                    ErrCode::SCHEMAP_DERIVATION_OK_RESTRICTION_2_1_1,
                    get_component_node(item), item, cur,
                    "The 'optional' attribute use is inconsistent " \
                    "with the corresponding 'required' attribute use of " \
                    "the %s %s",
                    wxs_action_str(action),
                    get_component_designation(base_item),
                    nil, nil)
                elsif check_cosst_derived_ok(pctxt, cur.attr_decl.subtypes,
                  bcur.attr_decl.subtypes, 0) != 0
                  # SPEC (2.1.2) "R's {attribute declaration}'s {type definition} must be
                  # validly derived from B's {type definition} given the empty set as
                  # defined in Type Derivation OK (Simple) ($3.14.6)."
                  p_attr_use_err4(pctxt,
                    ErrCode::SCHEMAP_DERIVATION_OK_RESTRICTION_2_1_2,
                    get_component_node(item), item, cur,
                    "The attribute declaration's %s " \
                    "is not validly derived from " \
                    "the corresponding %s of the " \
                    "attribute declaration in the %s %s",
                    get_component_designation(cur.attr_decl.subtypes),
                    get_component_designation(bcur.attr_decl.subtypes),
                    wxs_action_str(action),
                    get_component_designation(base_item))
                else
                  # 2.1.3 [Definition:] Let the effective value constraint of an attribute
                  # use be its {value constraint}, if present, otherwise its {attribute
                  # declaration}'s {value constraint} .
                  _, eff_fixed, b_eff_value, = get_effective_value_constraint(bcur)
                  # 2.1.3 ... one of the following must be true
                  # 2.1.3.1 B's `effective value constraint` is `absent` or default.
                  if !b_eff_value.nil? && eff_fixed == 1
                    # NOTE: libxml2 queries bcur again here (not cur), so this effectively
                    # never fails; ported as is.
                    _, eff_fixed, r_eff_value, = get_effective_value_constraint(bcur)
                    # 2.1.3.2 R's `effective value constraint` is fixed with the same string
                    # as B's.
                    if eff_fixed == 0 || !r_eff_value.equal?(b_eff_value)
                      p_attr_use_err4(pctxt,
                        ErrCode::SCHEMAP_DERIVATION_OK_RESTRICTION_2_1_3,
                        get_component_node(item), item, cur,
                        "The effective value constraint of the " \
                        "attribute use is inconsistent with " \
                        "its correspondent in the %s %s",
                        wxs_action_str(action),
                        get_component_designation(base_item),
                        nil, nil)
                    end
                  end
                end
                break
              end
            end
            # not_found:
            next if found

            # (2.2) "otherwise the {base type definition} must have an {attribute
            # wildcard} and the {target namespace} of the R's {attribute declaration} must
            # be `valid` with respect to that wildcard, as defined in Wildcard allows
            # Namespace Name ($3.10.4)."
            if base_wild.nil? ||
                check_cvc_wildcard_namespace(base_wild, cur.attr_decl.target_namespace) != 0
              p_attr_use_err4(pctxt,
                ErrCode::SCHEMAP_DERIVATION_OK_RESTRICTION_2_2,
                get_component_node(item), item, cur,
                "Neither a matching attribute use, " \
                "nor a matching wildcard exists in the %s %s",
                wxs_action_str(action),
                get_component_designation(base_item),
                nil, nil)
            end
          end
        end
        # SPEC derivation-ok-restriction (3):
        # (3) "For each attribute use in the {attribute uses} of the {base type definition}
        # whose {required} is true, there must be an attribute use with an {attribute
        # declaration} with the same {name} and {target namespace} as its {attribute
        # declaration} in the {attribute uses} of the complex type definition itself whose
        # {required} is true.
        if base_uses
          base_uses.items.each do |bcur|
            next if bcur.occurs != XML_SCHEMAS_ATTR_USE_REQUIRED

            found = false
            if uses
              uses.items.each do |c|
                cur = c
                if cur.attr_decl.name == bcur.attr_decl.name &&
                    cur.attr_decl.target_namespace == bcur.attr_decl.target_namespace
                  found = true
                  break
                end
              end
            end
            unless found
              custom_err4(pctxt,
                ErrCode::SCHEMAP_DERIVATION_OK_RESTRICTION_3,
                nil, item,
                "A matching attribute use for the " \
                "'required' %s of the %s %s is missing",
                get_component_designation(bcur),
                wxs_action_str(action),
                get_component_designation(base_item),
                nil)
            end
          end
        end
        # derivation-ok-restriction (4)
        if wild
          # (4) "If there is an {attribute wildcard}, all of the following must be true:"
          if base_wild.nil?
            # (4.1) "The {base type definition} must also have one."
            custom_err4(pctxt,
              ErrCode::SCHEMAP_DERIVATION_OK_RESTRICTION_4_1,
              nil, item,
              "The %s has an attribute wildcard, " \
              "but the %s %s '%s' does not have one",
              get_component_type_str(item),
              wxs_action_str(action),
              get_component_type_str(base_item),
              get_component_q_name(base_item))
            return pctxt.err
          elsif base_wild.any == 0 && check_cosns_subset(wild, base_wild) != 0
            # (4.2) "The complex type definition's {attribute wildcard}'s {namespace
            # constraint} must be a subset of the {base type definition}'s {attribute
            # wildcard}'s {namespace constraint}, as defined by Wildcard Subset ($3.10.6)."
            custom_err4(pctxt,
              ErrCode::SCHEMAP_DERIVATION_OK_RESTRICTION_4_2,
              nil, item,
              "The attribute wildcard is not a valid " \
              "subset of the wildcard in the %s %s '%s'",
              wxs_action_str(action),
              get_component_type_str(base_item),
              get_component_q_name(base_item),
              nil)
            return pctxt.err
          end
          # 4.3 Unless the {base type definition} is the `ur-type definition`, the complex
          # type definition's {attribute wildcard}'s {process contents} must be identical to
          # or stronger than the {base type definition}'s {attribute wildcard}'s {process
          # contents}, where strict is stronger than lax is stronger than skip.
          if !wxs_is_anytype(base_item) && wild.process_contents < base_wild.process_contents
            custom_err4(pctxt,
              ErrCode::SCHEMAP_DERIVATION_OK_RESTRICTION_4_3,
              nil, base_item,
              "The {process contents} of the attribute wildcard is " \
              "weaker than the one in the %s %s '%s'",
              wxs_action_str(action),
              get_component_type_str(base_item),
              get_component_q_name(base_item),
              nil)
            return pctxt.err
          end
        end
        0
      end

      # xmlSchemaFixupTypeAttributeUses
      # Builds the wildcard and the attribute uses on the given complex type.
      # Returns -1 if an internal error occurs, 0 otherwise.
      def fixup_type_attribute_uses(pctxt, type)
        prohibs = nil
        if type.base_type.nil?
          internal_err(pctxt, "xmlSchemaFixupTypeAttributeUses", "no base type")
          return -1
        end
        base_type = type.base_type
        if wxs_is_type_not_fixed(base_type)
          return -1 if type_fixup(base_type, pctxt) == -1
        end

        uses = type.attr_uses
        base_uses = base_type.attr_uses
        # Expand attribute group references. And build the 'complete' wildcard, i.e.
        # intersect multiple wildcards. Move attribute prohibitions into a separate list.
        if uses
          if wxs_is_restriction(type)
            # This one will transfer all attr. prohibitions into pctxt->attrProhibs.
            ret, type.attribute_wildcard = expand_attribute_group_refs(pctxt, type,
              type.attribute_wildcard, uses, pctxt.attr_prohibs)
            if ret == -1
              internal_err(pctxt, "xmlSchemaFixupTypeAttributeUses", "failed to expand attributes")
              return -1
            end
            prohibs = pctxt.attr_prohibs if pctxt.attr_prohibs.nb_items != 0
          else
            ret, type.attribute_wildcard = expand_attribute_group_refs(pctxt, type,
              type.attribute_wildcard, uses, nil)
            if ret == -1
              internal_err(pctxt, "xmlSchemaFixupTypeAttributeUses", "failed to expand attributes")
              return -1
            end
          end
        end
        # Inherit the attribute uses of the base type.
        if base_uses
          if wxs_is_restriction(type)
            uses_count = uses ? uses.nb_items : 0

            # Restriction.
            base_uses.items.each do |use|
              # Filter out prohibited uses.
              if prohibs && prohibs.items.any? { |pro|
                use.attr_decl.name == pro.name && use.attr_decl.target_namespace == pro.target_namespace
              }
                next
              end
              if uses_count > 0
                # Filter out existing uses.
                skip = false
                j = 0
                while j < uses_count
                  tmp = uses.items[j]
                  if use.attr_decl.name == tmp.attr_decl.name &&
                      use.attr_decl.target_namespace == tmp.attr_decl.target_namespace
                    skip = true
                    break
                  end
                  j += 1
                end
                next if skip
              end
              if uses.nil?
                type.attr_uses = SchemaItemList.new
                uses = type.attr_uses
              end
              uses.items << use
            end
          else
            # Extension.
            base_uses.items.each do |use|
              if uses.nil?
                type.attr_uses = SchemaItemList.new
                uses = type.attr_uses
              end
              uses.items << use
            end
          end
        end
        # Shrink attr. uses.
        type.attr_uses = nil if uses && uses.nb_items == 0
        # Compute the complete wildcard.
        if wxs_is_extension(type)
          unless base_type.attribute_wildcard.nil?
            # (3.2.2.1) "If the `base wildcard` is non-`absent`, then the appropriate case
            # among the following:"
            if !type.attribute_wildcard.nil?
              # Union the complete wildcard with the base wildcard.
              return -1 if union_wildcards(pctxt, type.attribute_wildcard,
                base_type.attribute_wildcard) == -1
            else
              # (3.2.2.1.1) "If the `complete wildcard` is `absent`, then the `base wildcard`."
              type.attribute_wildcard = base_type.attribute_wildcard
            end
          end
          # (3.2.2.2) "otherwise (the `base wildcard` is `absent`) the `complete wildcard`" NOOP
        end
        # SPEC {attribute wildcard} (3.1) "If the <restriction> alternative is chosen, then the
        # `complete wildcard`;" NOOP
        0
      end

      # xmlSchemaTypeFinalContains
      # Evaluates if a type definition contains the given "final".
      # Returns 1 if the type does contain the given "final", 0 otherwise.
      def type_final_contains(type, final)
        return 0 if type.nil?

        (type.flags & final) != 0 ? 1 : 0
      end

      # xmlSchemaGetUnionSimpleTypeMemberTypes
      # Returns a list of member types of type if existing, returns NULL otherwise.
      def get_union_simple_type_member_types(type)
        while !type.nil? && type.type == XML_SCHEMA_TYPE_SIMPLE
          return type.member_types unless type.member_types.nil?

          type = type.base_type
        end
        nil
      end

      # xmlSchemaGetParticleTotalRangeMin (#if 0 in C; kept for completeness)
      # Schema Component Constraint: Effective Total Range (all and sequence) + (choice)
      def get_particle_total_range_min(particle)
        return 0 if particle.children.nil? || particle.min_occurs == 0

        if particle.children.type == XML_SCHEMA_TYPE_CHOICE
          min = -1
          part = particle.children.children
          return 0 if part.nil?

          while part
            cur = if part.children.type == XML_SCHEMA_TYPE_ELEMENT ||
                part.children.type == XML_SCHEMA_TYPE_ANY
              part.min_occurs
            else
              get_particle_total_range_min(part)
            end
            return 0 if cur == 0

            min = cur if min > cur || min == -1
            part = part.next
          end
          particle.min_occurs * min
        else
          # <all> and <sequence>
          sum = 0
          part = particle.children.children
          return 0 if part.nil?

          while part
            sum += if part.children.type == XML_SCHEMA_TYPE_ELEMENT ||
                part.children.type == XML_SCHEMA_TYPE_ANY
              part.min_occurs
            else
              get_particle_total_range_min(part)
            end
            part = part.next
          end
          particle.min_occurs * sum
        end
      end

      # xmlSchemaGetParticleTotalRangeMax (#if 0 in C; kept for completeness)
      def get_particle_total_range_max(particle)
        return 0 if particle.children.nil? || particle.children.children.nil?

        if particle.children.type == XML_SCHEMA_TYPE_CHOICE
          max = -1
          part = particle.children.children
          while part
            unless part.children.nil?
              cur = if part.children.type == XML_SCHEMA_TYPE_ELEMENT ||
                  part.children.type == XML_SCHEMA_TYPE_ANY
                part.max_occurs
              else
                get_particle_total_range_max(part)
              end
              return UNBOUNDED if cur == UNBOUNDED

              max = cur if max < cur || max == -1
            end
            part = part.next
          end
          particle.max_occurs * max
        else
          # <all> and <sequence>
          sum = 0
          part = particle.children.children
          while part
            unless part.children.nil?
              cur = if part.children.type == XML_SCHEMA_TYPE_ELEMENT ||
                  part.children.type == XML_SCHEMA_TYPE_ANY
                part.max_occurs
              else
                get_particle_total_range_max(part)
              end
              return UNBOUNDED if cur == UNBOUNDED
              return UNBOUNDED if cur > 0 && particle.max_occurs == UNBOUNDED

              sum += cur
            end
            part = part.next
          end
          particle.max_occurs * sum
        end
      end

      # xmlSchemaGetParticleEmptiable
      # Returns 1 if emptiable, 0 otherwise.
      def get_particle_emptiable(particle)
        return 1 if particle.children.nil? || particle.min_occurs == 0

        part = particle.children.children
        return 1 if part.nil?

        is_choice = particle.children.type == XML_SCHEMA_TYPE_CHOICE
        while part
          emptiable = if part.children.type == XML_SCHEMA_TYPE_ELEMENT ||
              part.children.type == XML_SCHEMA_TYPE_ANY
            part.min_occurs == 0
          else
            get_particle_emptiable(part) != 0
          end
          if is_choice
            return 1 if emptiable
          else
            # <all> and <sequence>
            return 0 unless emptiable
          end
          part = part.next
        end

        is_choice ? 0 : 1
      end

      # xmlSchemaIsParticleEmptiable
      # Schema Component Constraint: Particle Emptiable
      # Returns 1 if emptiable, 0 otherwise.
      def is_particle_emptiable(particle)
        # SPEC (1) "Its {min occurs} is 0."
        return 1 if particle.nil? || particle.min_occurs == 0 || particle.children.nil?
        # SPEC (2) "Its {term} is a group and the minimum part of the effective total range
        # of that group, [...] is 0."
        return get_particle_emptiable(particle) if wxs_is_model_group(particle.children)

        0
      end

      # xmlSchemaCheckCOSSTDerivedOK
      # Schema Component Constraint: Type Derivation OK (Simple) (cos-st-derived-OK)
      # Checks whether type can be validly derived from baseType.
      # Returns 0 on success, an positive error code otherwise.
      def check_cosst_derived_ok(actxt, type, base_type, subset)
        # 1 They are the same type definition.
        return 0 if type.equal?(base_type)

        # 2.1 restriction is not in the subset, or in the {final} of its own {base type
        # definition};
        if wxs_is_type_not_fixed(type)
          return -1 if type_fixup(type, actxt) == -1
        end
        if wxs_is_type_not_fixed(base_type)
          return -1 if type_fixup(base_type, actxt) == -1
        end
        if (subset & SUBSET_RESTRICTION) != 0 ||
            type_final_contains(type.base_type, XML_SCHEMAS_TYPE_FINAL_RESTRICTION) != 0
          return ErrCode::SCHEMAP_COS_ST_DERIVED_OK_2_1
        end
        # 2.2
        # 2.2.1 D's `base type definition` is B.
        return 0 if type.base_type.equal?(base_type)

        # 2.2.2 D's `base type definition` is not the `ur-type definition` and is validly
        # derived from B given the subset, as defined by this constraint.
        if !wxs_is_anytype(type.base_type) &&
            check_cosst_derived_ok(actxt, type.base_type, base_type, subset) == 0
          return 0
        end
        # 2.2.3 D's {variety} is list or union and B is the `simple ur-type definition`.
        if wxs_is_any_simple_type(base_type) && (wxs_is_list(type) || wxs_is_union(type))
          return 0
        end
        # 2.2.4 B's {variety} is union and D is validly derived from a type definition in
        # B's {member type definitions} given the subset, as defined by this constraint.
        if wxs_is_union(base_type)
          cur = base_type.member_types
          while cur
            if wxs_is_type_not_fixed(cur.type)
              return -1 if type_fixup(cur.type, actxt) == -1
            end
            # It just has to be validly derived from at least one member-type.
            return 0 if check_cosst_derived_ok(actxt, type, cur.type, subset) == 0

            cur = cur.next
          end
        end
        ErrCode::SCHEMAP_COS_ST_DERIVED_OK_2_2
      end

      # xmlSchemaCheckTypeDefCircularInternal
      # Checks st-props-correct (2) + ct-props-correct (3). Circular type definitions are
      # not allowed. Returns XML_SCHEMAP_ST_PROPS_CORRECT_2 if the given type is circular,
      # 0 otherwise.
      def check_type_def_circular_internal(pctxt, ctxt_type, ancestor)
        return 0 if ancestor.nil? || ancestor.type == XML_SCHEMA_TYPE_BASIC

        if ctxt_type.equal?(ancestor)
          p_custom_err(pctxt, ErrCode::SCHEMAP_ST_PROPS_CORRECT_2,
            ctxt_type, get_component_node(ctxt_type),
            "The definition is circular", nil)
          return ErrCode::SCHEMAP_ST_PROPS_CORRECT_2
        end
        # Avoid infinite recursion on circular types not yet checked.
        return 0 if (ancestor.flags & XML_SCHEMAS_TYPE_MARKED) != 0

        ancestor.flags |= XML_SCHEMAS_TYPE_MARKED
        ret = check_type_def_circular_internal(pctxt, ctxt_type, ancestor.base_type)
        ancestor.flags ^= XML_SCHEMAS_TYPE_MARKED
        ret
      end

      # xmlSchemaCheckTypeDefCircular
      # Checks for circular type definitions.
      def check_type_def_circular(item, ctxt)
        return if item.nil? || item.type == XML_SCHEMA_TYPE_BASIC || item.base_type.nil?

        check_type_def_circular_internal(ctxt, item, item.base_type)
      end

      # xmlSchemaCheckUnionTypeDefCircularRecur
      # Simple Type Definition Representation OK (src-simple-type) 4
      def check_union_type_def_circular_recur(pctxt, ctx_type, members)
        member = members
        while member
          member_type = member.type
          while !member_type.nil? && member_type.type != XML_SCHEMA_TYPE_BASIC
            if member_type.equal?(ctx_type)
              p_custom_err(pctxt, ErrCode::SCHEMAP_SRC_SIMPLE_TYPE_4,
                ctx_type, nil,
                "The union type definition is circular", nil)
              return ErrCode::SCHEMAP_SRC_SIMPLE_TYPE_4
            end
            if wxs_is_union(member_type) && (member_type.flags & XML_SCHEMAS_TYPE_MARKED) == 0
              member_type.flags |= XML_SCHEMAS_TYPE_MARKED
              res = check_union_type_def_circular_recur(pctxt, ctx_type,
                get_union_simple_type_member_types(member_type))
              member_type.flags ^= XML_SCHEMAS_TYPE_MARKED
              return res if res != 0
            end
            member_type = member_type.base_type
          end
          member = member.next
        end
        0
      end

      # xmlSchemaCheckUnionTypeDefCircular
      def check_union_type_def_circular(pctxt, type)
        return 0 unless wxs_is_union(type)

        check_union_type_def_circular_recur(pctxt, type, type.member_types)
      end

      # xmlSchemaResolveTypeReferences
      # Resolves type definition references
      def resolve_type_references(type_def, ctxt)
        return if type_def.nil?

        # Resolve the base type.
        if type_def.base_type.nil?
          type_def.base_type = get_type(ctxt.schema, type_def.base, type_def.base_ns)
          if type_def.base_type.nil?
            p_res_comp_attr_err(ctxt, ErrCode::SCHEMAP_SRC_RESOLVE,
              type_def, type_def.node,
              "base", type_def.base, type_def.base_ns,
              XML_SCHEMA_TYPE_SIMPLE, nil)
            return
          end
        end
        if wxs_is_simple(type_def)
          if wxs_is_union(type_def)
            # Resolve the memberTypes.
            resolve_union_member_types(ctxt, type_def)
            nil
          elsif wxs_is_list(type_def)
            # Resolve the itemType.
            if type_def.subtypes.nil? && !type_def.base.nil?
              type_def.subtypes = get_type(ctxt.schema, type_def.base, type_def.base_ns)

              if type_def.subtypes.nil? || !wxs_is_simple(type_def.subtypes)
                type_def.subtypes = nil
                p_res_comp_attr_err(ctxt, ErrCode::SCHEMAP_SRC_RESOLVE,
                  type_def, type_def.node,
                  "itemType", type_def.base, type_def.base_ns,
                  XML_SCHEMA_TYPE_SIMPLE, nil)
              end
            end
            nil
          end
        # The ball of letters below means, that if we have a particle which has a
        # QName-helper component as its {term}, we want to resolve it...
        elsif !type_def.subtypes.nil? &&
            type_def.subtypes.type == XML_SCHEMA_TYPE_PARTICLE &&
            !type_def.subtypes.children.nil? &&
            type_def.subtypes.children.type == XML_SCHEMA_EXTRA_QNAMEREF
          ref = type_def.subtypes.children
          type_def.subtypes.children = nil
          # Resolve the MG definition reference.
          group_def = get_named_component(ctxt.schema, ref.item_type, ref.name,
            ref.target_namespace)
          if group_def.nil?
            p_res_comp_attr_err(ctxt, ErrCode::SCHEMAP_SRC_RESOLVE,
              nil, get_component_node(type_def.subtypes),
              "ref", ref.name, ref.target_namespace, ref.item_type, nil)
            # Remove the particle.
            type_def.subtypes = nil
          elsif group_def.children.nil?
            # Remove the particle.
            type_def.subtypes = nil
          else
            # Assign the MG definition's {model group} to the particle's {term}.
            type_def.subtypes.children = group_def.children

            if group_def.children.type == XML_SCHEMA_TYPE_ALL
              # SPEC cos-all-limited (1.2) "1.2 the {term} property of a particle with
              # {max occurs}=1 which is part of a pair which constitutes the {content type}
              # of a complex type definition."
              if type_def.subtypes.max_occurs != 1
                custom_err(ctxt,
                  ErrCode::SCHEMAP_COS_ALL_LIMITED,
                  get_component_node(type_def.subtypes), nil,
                  "The particle's {max occurs} must be 1, since the " \
                  "reference resolves to an 'all' model group",
                  nil, nil)
              end
            end
          end
        end
      end
    end
  end
end
