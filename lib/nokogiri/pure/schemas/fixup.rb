# frozen_string_literal: true

require_relative "structs"
require_relative "macros"
require_relative "common"

# Port of xmlschemas.c (2.13.9) lines ~18091-19950: complex type fixup, xmlSchemaTypeFixup,
# facet checking (xmlSchemaCheckFacet, public), circularity checks of model group
# definitions / attribute groups / substitution groups, attribute group expansion and the
# element/attribute declaration property checks.
module Nokogiri
  module Pure
    module Schemas
      extend self

      # xmlSchemaFixupComplexType
      def fixup_complex_type(pctxt, type)
        olderrs = pctxt.nberrors
        base_type = type.base_type

        return 0 unless wxs_is_type_not_fixed(type)

        type.flags |= XML_SCHEMAS_TYPE_INTERNAL_RESOLVED
        exit_failure = lambda do
          type.flags |= XML_SCHEMAS_TYPE_INTERNAL_INVALID
          -1
        end
        exit_error = lambda do
          type.flags |= XML_SCHEMAS_TYPE_INTERNAL_INVALID
          pctxt.err
        end

        if base_type.nil?
          internal_err(pctxt, "xmlSchemaFixupComplexType", "missing baseType")
          return exit_failure.()
        end
        # Fixup the base type.
        type_fixup(base_type, pctxt) if wxs_is_type_not_fixed(base_type)
        # Skip fixup if the base type is invalid.
        return 0 if (base_type.flags & XML_SCHEMAS_TYPE_INTERNAL_INVALID) != 0

        # This basically checks if the base type can be derived.
        res = check_srcct(pctxt, type)
        return exit_failure.() if res == -1
        return exit_error.() if res != 0

        # Fixup the content type.
        if type.content_type == XML_SCHEMA_CONTENT_SIMPLE
          # Corresponds to <complexType><simpleContent>...
          if wxs_is_complex(base_type) && !base_type.content_type_def.nil? &&
              wxs_is_restriction(type)
            # SPEC (1) If <restriction> + base type is <complexType>, "whose own {content
            # type} is a simple type..."
            if !type.content_type_def.nil?
              # SPEC (1.1) the <simpleType> among the [children] of <restriction>
              content_base = type.content_type_def
              type.content_type_def = nil
            else
              # (1.2) the {content type} of the ... base type.
              content_base = base_type.content_type_def
            end
            # Create the anonymous simple type, which will be the content type of the
            # complex type.
            content = add_type(pctxt, pctxt.schema, XML_SCHEMA_TYPE_SIMPLE, nil,
              type.target_namespace, type.node, 0)
            return exit_failure.() if content.nil?

            # We will use the same node as for the <complexType> to have it somehow
            # anchored in the schema doc.
            content.type = XML_SCHEMA_TYPE_SIMPLE
            content.base_type = content_base
            # Move the facets, previously anchored on the complexType during parsing.
            content.facets = type.facets
            type.facets = nil
            content.facet_set = type.facet_set
            type.facet_set = nil

            type.content_type_def = content
            type_fixup(content_base, pctxt) if wxs_is_type_not_fixed(content_base)
            # Fixup the newly created type. We don't need to check for circularity here.
            res = fixup_simple_type_stage_one(pctxt, content)
            return exit_failure.() if res == -1
            return exit_error.() if res != 0

            res = fixup_simple_type_stage_two(pctxt, content)
            return exit_failure.() if res == -1
            return exit_error.() if res != 0
          elsif wxs_is_complex(base_type) &&
              base_type.content_type == XML_SCHEMA_CONTENT_MIXED &&
              wxs_is_restriction(type)
            # SPEC (2) If <restriction> + base is a mixed <complexType> with an emptiable
            # particle, then a simple type definition which restricts the <restriction>'s
            # <simpleType> child.
            if type.content_type_def.nil? || type.content_type_def.base_type.nil?
              p_custom_err(pctxt, ErrCode::SCHEMAP_INTERNAL,
                type, nil,
                "Internal error: xmlSchemaTypeFixup, " \
                "complex type '%s': the <simpleContent><restriction> " \
                "is missing a <simpleType> child, but was not caught " \
                "by xmlSchemaCheckSRCCT()", type.name)
              return exit_failure.()
            end
          elsif wxs_is_complex(base_type) && wxs_is_extension(type)
            # SPEC (3) If <extension> + base is <complexType> with <simpleType> content,
            # "...then the {content type} of that complex type definition"
            if base_type.content_type_def.nil?
              p_custom_err(pctxt, ErrCode::SCHEMAP_INTERNAL,
                type, nil,
                "Internal error: xmlSchemaTypeFixup, " \
                "complex type '%s': the <extension>ed base type is " \
                "a complex type with no simple content type",
                type.name)
              return exit_failure.()
            end
            type.content_type_def = base_type.content_type_def
          elsif wxs_is_simple(base_type) && wxs_is_extension(type)
            # SPEC (4) <extension> + base is <simpleType> "... then that simple type
            # definition"
            type.content_type_def = base_type
          else
            p_custom_err(pctxt, ErrCode::SCHEMAP_INTERNAL,
              type, nil,
              "Internal error: xmlSchemaTypeFixup, " \
              "complex type '%s' with <simpleContent>: unhandled " \
              "derivation case", type.name)
            return exit_failure.()
          end
        else
          dummy_sequence = false
          particle = type.subtypes
          # Corresponds to <complexType><complexContent>...
          # Compute the "effective content": (2.1.1) + (2.1.2) + (2.1.3)
          if particle.nil? ||
              (particle.type == XML_SCHEMA_TYPE_PARTICLE &&
               (particle.children.type == XML_SCHEMA_TYPE_ALL ||
                particle.children.type == XML_SCHEMA_TYPE_SEQUENCE ||
                (particle.children.type == XML_SCHEMA_TYPE_CHOICE && particle.min_occurs == 0)) &&
               particle.children.children.nil?)
            if (type.flags & XML_SCHEMAS_TYPE_MIXED) != 0
              # SPEC (2.1.4) "If the `effective mixed` is true, then a particle whose
              # properties are as follows:..." Empty sequence model group with
              # minOccurs/maxOccurs = 1.
              if particle.nil? || particle.children.type != XML_SCHEMA_TYPE_SEQUENCE
                # Create the particle.
                particle = add_particle(pctxt, type.node, 1, 1)
                return exit_failure.() if particle.nil?

                # Create the model group.
                particle.children = add_model_group(pctxt, pctxt.schema,
                  XML_SCHEMA_TYPE_SEQUENCE, type.node)
                return exit_failure.() if particle.children.nil?

                type.subtypes = particle
              end
              dummy_sequence = true
              type.content_type = XML_SCHEMA_CONTENT_ELEMENTS
            else
              # SPEC (2.1.5) "otherwise empty"
              type.content_type = XML_SCHEMA_CONTENT_EMPTY
            end
          else
            # SPEC (2.2) "otherwise the particle corresponding to the <all>, <choice>,
            # <group> or <sequence> among the [children]."
            type.content_type = XML_SCHEMA_CONTENT_ELEMENTS
          end
          # Compute the "content type".
          if wxs_is_restriction(type)
            # SPEC (3.1) "If <restriction>..." (3.1.1) + (3.1.2)
            if type.content_type != XML_SCHEMA_CONTENT_EMPTY
              type.content_type = XML_SCHEMA_CONTENT_MIXED if (type.flags & XML_SCHEMAS_TYPE_MIXED) != 0
            end
          else
            # SPEC (3.2) "If <extension>..."
            if type.content_type == XML_SCHEMA_CONTENT_EMPTY
              # SPEC (3.2.1) "If the `effective content` is empty, then the {content type}
              # of the [...] base ..."
              type.content_type = base_type.content_type
              type.subtypes = base_type.subtypes
              # Fixes bug #347316: This is the case when the base type has a simple type
              # definition as content.
              type.content_type_def = base_type.content_type_def
              # NOTE that the effective mixed is ignored here.
            elsif base_type.content_type == XML_SCHEMA_CONTENT_EMPTY
              # SPEC (3.2.2)
              type.content_type = XML_SCHEMA_CONTENT_MIXED if (type.flags & XML_SCHEMAS_TYPE_MIXED) != 0
            else
              # SPEC (3.2.3)
              type.content_type = XML_SCHEMA_CONTENT_MIXED if (type.flags & XML_SCHEMAS_TYPE_MIXED) != 0
              # "A model group whose {compositor} is sequence and whose {particles} are..."
              if !type.subtypes.nil? && !type.subtypes.children.nil? &&
                  type.subtypes.children.type == XML_SCHEMA_TYPE_ALL
                # SPEC cos-all-limited (1)
                custom_err(pctxt,
                  ErrCode::SCHEMAP_COS_ALL_LIMITED,
                  get_component_node(type), nil,
                  "The type has an 'all' model group in its " \
                  "{content type} and thus cannot be derived from " \
                  "a non-empty type, since this would produce a " \
                  "'sequence' model group containing the 'all' " \
                  "model group; 'all' model groups are not " \
                  "allowed to appear inside other model groups",
                  nil, nil)
              elsif !base_type.subtypes.nil? && !base_type.subtypes.children.nil? &&
                  base_type.subtypes.children.type == XML_SCHEMA_TYPE_ALL
                # SPEC cos-all-limited (1)
                custom_err(pctxt,
                  ErrCode::SCHEMAP_COS_ALL_LIMITED,
                  get_component_node(type), nil,
                  "A type cannot be derived by extension from a type " \
                  "which has an 'all' model group in its " \
                  "{content type}, since this would produce a " \
                  "'sequence' model group containing the 'all' " \
                  "model group; 'all' model groups are not " \
                  "allowed to appear inside other model groups",
                  nil, nil)
              elsif !dummy_sequence && !base_type.subtypes.nil?
                effective_content = type.subtypes
                # Create the particle.
                particle = add_particle(pctxt, type.node, 1, 1)
                return exit_failure.() if particle.nil?

                # Create the "sequence" model group.
                particle.children = add_model_group(pctxt, pctxt.schema,
                  XML_SCHEMA_TYPE_SEQUENCE, type.node)
                return exit_failure.() if particle.children.nil?

                type.subtypes = particle
                # SPEC "the particle of the {content type} of the ... base ..."
                # Create a duplicate of the base type's particle and assign its "term" to it.
                particle.children.children = add_particle(pctxt, type.node,
                  base_type.subtypes.min_occurs, base_type.subtypes.max_occurs)
                return exit_failure.() if particle.children.children.nil?

                particle = particle.children.children
                particle.children = base_type.subtypes.children
                # SPEC "followed by the `effective content`."
                particle.next = effective_content
              else
                # This is the case when there is already an empty <sequence> with
                # minOccurs==maxOccurs==1. Just add the base types's content type.
                particle.children.children = base_type.subtypes
              end
            end
          end
        end
        # Now fixup attribute uses:
        #   - expand attr. group references
        #     - intersect attribute wildcards
        #   - inherit attribute uses of the base type
        #   - inherit or union attr. wildcards if extending
        #   - apply attr. use prohibitions if restricting
        res = fixup_type_attribute_uses(pctxt, type)
        return exit_failure.() if res == -1
        return exit_error.() if res != 0

        # Apply the complex type component constraints; this will not check attributes,
        # since this is done in xmlSchemaFixupTypeAttributeUses().
        res = check_ct_component(pctxt, type)
        return exit_failure.() if res == -1
        return exit_error.() if res != 0

        return pctxt.err if olderrs != pctxt.nberrors

        0
      end

      # xmlSchemaTypeFixup
      # Fixes the content model of the type.
      def type_fixup(type, actxt)
        return 0 if type.nil?

        if actxt.type != XML_SCHEMA_CTXT_PARSER
          internal_err(actxt, "xmlSchemaTypeFixup", "this function needs a parser context")
          return -1
        end
        return 0 unless wxs_is_type_not_fixed(type)

        if type.type == XML_SCHEMA_TYPE_COMPLEX
          fixup_complex_type(actxt, type)
        elsif type.type == XML_SCHEMA_TYPE_SIMPLE
          fixup_simple_type_stage_two(actxt, type)
        else
          0
        end
      end

      # xmlSchemaCheckFacet (public API)
      # Checks and computes the values of facets.
      # Returns 0 if valid, a positive error code if not valid and -1 in case of an internal
      # or API error.
      def check_facet(facet, type_decl, pctxt, name = nil)
        ret = 0
        return -1 if facet.nil? || type_decl.nil?

        ctxt_given = !pctxt.nil?

        case facet.type
        when XML_SCHEMA_FACET_MININCLUSIVE, XML_SCHEMA_FACET_MINEXCLUSIVE,
          XML_SCHEMA_FACET_MAXINCLUSIVE, XML_SCHEMA_FACET_MAXEXCLUSIVE,
          XML_SCHEMA_FACET_ENUMERATION
          # Okay we need to validate the value at that point.
          # 4.3.5.5 Constraints on enumeration Schema Components ... The value `must` be
          # in the `value space` of the `base type`.
          if type_decl.type != XML_SCHEMA_TYPE_BASIC
            base = type_decl.base_type
            if base.nil?
              internal_err(pctxt, "xmlSchemaCheckFacet",
                "a type user derived type has no base type")
              return -1
            end
          else
            base = type_decl
          end

          unless ctxt_given
            # A context is needed if called from RelaxNG.
            pctxt = new_parser_ctxt("*")
            return -1 if pctxt.nil?
          end
          # NOTE: This call does not check the content nodes, since they are not available:
          # facet->node is just the node holding the facet definition, *not* the attribute
          # holding the *value* of the facet.
          ret, facet.val = v_check_cvc_simple_type(pctxt, facet.node, base,
            facet.value, true, 1, 1, 0)
          if ret != 0
            if ret < 0
              # No error message for RelaxNG.
              if ctxt_given
                custom_err(pctxt, ErrCode::SCHEMAP_INTERNAL, facet.node, nil,
                  "Internal error: xmlSchemaCheckFacet, " \
                  "failed to validate the value '%s' of the " \
                  "facet '%s' against the base type",
                  facet.value, facet_type_to_string(facet.type))
              end
              return -1
            end
            ret = ErrCode::SCHEMAP_INVALID_FACET_VALUE
            # No error message for RelaxNG.
            if ctxt_given
              custom_err(pctxt, ret, facet.node, facet,
                "The value '%s' of the facet does not validate " \
                "against the base type '%s'",
                facet.value,
                format_q_name(base.target_namespace, base.name))
            end
            return ret
          elsif facet.val.nil?
            internal_err(pctxt, "xmlSchemaCheckFacet", "value was not computed") if ctxt_given
          end
        when XML_SCHEMA_FACET_PATTERN
          facet.regexp = XmlRegexp.regexp_compile(facet.value)
          if facet.regexp.nil?
            ret = ErrCode::SCHEMAP_REGEXP_INVALID
            # No error message for RelaxNG.
            if ctxt_given
              custom_err(pctxt, ret, facet.node, type_decl,
                "The value '%s' of the facet 'pattern' is not a " \
                "valid regular expression",
                facet.value, nil)
            end
          end
        when XML_SCHEMA_FACET_TOTALDIGITS, XML_SCHEMA_FACET_FRACTIONDIGITS,
          XML_SCHEMA_FACET_LENGTH, XML_SCHEMA_FACET_MAXLENGTH, XML_SCHEMA_FACET_MINLENGTH
          ret, facet.val = if facet.type == XML_SCHEMA_FACET_TOTALDIGITS
            Types.validate_predefined_type(
              Types.get_built_in_type(XML_SCHEMAS_PINTEGER), facet.value, true)
          else
            Types.validate_predefined_type(
              Types.get_built_in_type(XML_SCHEMAS_NNINTEGER), facet.value, true)
          end
          if ret != 0
            if ret < 0
              # No error message for RelaxNG.
              internal_err(pctxt, "xmlSchemaCheckFacet", "validating facet value") if ctxt_given
              return -1
            end
            ret = ErrCode::SCHEMAP_INVALID_FACET_VALUE
            # No error message for RelaxNG.
            if ctxt_given
              custom_err4(pctxt, ret, facet.node, type_decl,
                "The value '%s' of the facet '%s' is not a valid '%s'",
                facet.value,
                facet_type_to_string(facet.type),
                facet.type != XML_SCHEMA_FACET_TOTALDIGITS ? "nonNegativeInteger" : "positiveInteger",
                nil)
            end
          end
        when XML_SCHEMA_FACET_WHITESPACE
          case facet.value
          when "preserve"
            facet.whitespace = XML_SCHEMAS_FACET_PRESERVE
          when "replace"
            facet.whitespace = XML_SCHEMAS_FACET_REPLACE
          when "collapse"
            facet.whitespace = XML_SCHEMAS_FACET_COLLAPSE
          else
            ret = ErrCode::SCHEMAP_INVALID_FACET_VALUE
            # No error message for RelaxNG.
            if ctxt_given
              # error was previously: XML_SCHEMAP_INVALID_WHITE_SPACE
              custom_err(pctxt, ret, facet.node, type_decl,
                "The value '%s' of the facet 'whitespace' is not " \
                "valid", facet.value, nil)
            end
          end
        end
        ret
      end

      # xmlSchemaCheckFacetValues
      # Checks the default values types, especially for facets
      def check_facet_values(type_decl, pctxt)
        olderrs = pctxt.nberrors
        name = type_decl.name
        # NOTE: It is intended to use the facets list, instead of facetSet.
        unless type_decl.facets.nil?
          facet = type_decl.facets
          # Temporarily assign the "schema" to the validation context of the parser context.
          # This is needed for NOTATION validation.
          if pctxt.vctxt.nil?
            return -1 if create_v_ctxt_on_p_ctxt(pctxt) == -1
          end
          pctxt.vctxt.schema = pctxt.schema
          while facet
            res = check_facet(facet, type_decl, pctxt, name)
            return -1 if res == -1

            facet = facet.next
          end
          pctxt.vctxt.schema = nil
        end
        return pctxt.err if olderrs != pctxt.nberrors

        0
      end

      # xmlSchemaGetCircModelGrDefRef
      # Returns the particle with the circular model group definition reference, otherwise
      # NULL.
      def get_circ_model_gr_def_ref(group_def, particle)
        while particle
          term = particle.children
          unless term.nil?
            case term.type
            when XML_SCHEMA_TYPE_GROUP
              gdef = term
              return particle if gdef.equal?(group_def)

              # Mark this model group definition to avoid infinite recursion on circular
              # references not yet examined.
              if (gdef.flags & XML_SCHEMA_MODEL_GROUP_DEF_MARKED) == 0 && !gdef.children.nil?
                gdef.flags |= XML_SCHEMA_MODEL_GROUP_DEF_MARKED
                circ = get_circ_model_gr_def_ref(group_def, gdef.children.children)
                gdef.flags ^= XML_SCHEMA_MODEL_GROUP_DEF_MARKED
                return circ unless circ.nil?
              end
            when XML_SCHEMA_TYPE_SEQUENCE, XML_SCHEMA_TYPE_CHOICE, XML_SCHEMA_TYPE_ALL
              circ = get_circ_model_gr_def_ref(group_def, term.children)
              return circ unless circ.nil?
            end
          end
          particle = particle.next
        end
        nil
      end

      # xmlSchemaCheckGroupDefCircular
      # Checks for circular references to model group definitions.
      def check_group_def_circular(item, ctxt)
        # Schema Component Constraint: Model Group Correct
        # 2 Circular groups are disallowed.
        return if item.nil? || item.type != XML_SCHEMA_TYPE_GROUP || item.children.nil?

        circ = get_circ_model_gr_def_ref(item, item.children.children)
        unless circ.nil?
          p_custom_err(ctxt, ErrCode::SCHEMAP_MG_PROPS_CORRECT_2,
            nil, get_component_node(circ),
            "Circular reference to the model group definition '%s' " \
            "defined", format_q_name(item.target_namespace, item.name))
          # NOTE: We will cut the reference to avoid further confusion of the processor.
          # This is a fatal error.
          circ.children = nil
        end
      end

      # xmlSchemaModelGroupToModelGroupDefFixup
      # Assigns the model group of model group definitions to the "term" of the referencing
      # particle. Schema Component Constraint: All Group Limited (cos-all-limited) (1.2)
      def model_group_to_model_group_def_fixup(ctxt, mg)
        particle = mg.children
        while particle
          if particle.children.nil? || particle.children.type != XML_SCHEMA_TYPE_GROUP
            particle = particle.next
            next
          end
          if particle.children.children.nil?
            # TODO: Remove the particle.
            particle.children = nil
            particle = particle.next
            next
          end
          # Assign the model group to the {term} of the particle.
          particle.children = particle.children.children
          particle = particle.next
        end
      end

      # xmlSchemaCheckAttrGroupCircularRecur
      # Returns the circular attribute group reference, otherwise NULL.
      def check_attr_group_circular_recur(ctxt_gr, list)
        # We will search for an attribute group reference which references the context
        # attribute group.
        list.items.each do |ref|
          next unless ref.type == XML_SCHEMA_EXTRA_QNAMEREF &&
            ref.item_type == XML_SCHEMA_TYPE_ATTRIBUTEGROUP && !ref.item.nil?

          gr = ref.item
          return ref if gr.equal?(ctxt_gr)
          next if (gr.flags & XML_SCHEMAS_ATTRGROUP_MARKED) != 0

          # Mark as visited to avoid infinite recursion on circular references not yet
          # examined.
          if gr.attr_uses && (gr.flags & XML_SCHEMAS_ATTRGROUP_HAS_REFS) != 0
            gr.flags |= XML_SCHEMAS_ATTRGROUP_MARKED
            circ = check_attr_group_circular_recur(ctxt_gr, gr.attr_uses)
            gr.flags ^= XML_SCHEMAS_ATTRGROUP_MARKED
            return circ unless circ.nil?
          end
        end
        nil
      end

      # xmlSchemaCheckAttrGroupCircular
      # Checks for circular references of attribute groups.
      def check_attr_group_circular(attr_gr, ctxt)
        # Schema Representation Constraint: Attribute Group Definition Representation OK
        # 3 Circular group reference is disallowed outside <redefine>.
        return 0 if attr_gr.attr_uses.nil?
        return 0 if (attr_gr.flags & XML_SCHEMAS_ATTRGROUP_HAS_REFS) == 0

        circ = check_attr_group_circular_recur(attr_gr, attr_gr.attr_uses)
        unless circ.nil?
          # TODO: Report the referenced attr group as QName.
          p_custom_err(ctxt, ErrCode::SCHEMAP_SRC_ATTRIBUTE_GROUP_3,
            nil, get_component_node(circ),
            "Circular reference to the attribute group '%s' " \
            "defined", get_component_q_name(attr_gr))
          # NOTE: We will cut the reference to avoid further confusion of the processor.
          circ.item = nil
          return ctxt.err
        end
        0
      end

      # xmlSchemaExpandAttributeGroupRefs
      # Substitutes contained attribute group references for their attribute uses.
      # Wildcards are intersected. Attribute use prohibitions are removed from the list and
      # returned via the prohibs list. Pointlessness of attr. prohibs, if a matching attr.
      # decl is existent a well, are checked.
      # C: (pctxt, item, xmlSchemaWildcardPtr *completeWild, list, prohibs)  (in/out)
      # Ruby: expand_attribute_group_refs(pctxt, item, complete_wild, list, prohibs)
      #       -> [ret, complete_wild]
      def expand_attribute_group_refs(pctxt, item, complete_wild, list, prohibs)
        created = complete_wild.nil? ? false : true

        prohibs&.items&.clear

        items = list.items
        i = 0
        while i < items.size
          use = items[i]

          if use.type == XML_SCHEMA_EXTRA_ATTR_USE_PROHIB
            if prohibs.nil?
              internal_err(pctxt, "xmlSchemaExpandAttributeGroupRefs",
                "unexpected attr prohibition found")
              return [-1, complete_wild]
            end
            # Remove from attribute uses.
            items.delete_at(i)
            # Note that duplicate prohibitions were already handled at parsing time.
            # Add to list of prohibitions.
            prohibs.items << use
            next
          end
          if use.type == XML_SCHEMA_EXTRA_QNAMEREF && use.item_type == XML_SCHEMA_TYPE_ATTRIBUTEGROUP
            return [-1, complete_wild] if use.item.nil?

            gr = use.item
            # Expand the referenced attr. group.
            if (gr.flags & XML_SCHEMAS_ATTRGROUP_WILDCARD_BUILDED) == 0
              return [-1, complete_wild] if attribute_group_expand_refs(pctxt, gr) == -1
            end
            # Build the 'complete' wildcard; i.e. intersect multiple wildcards.
            unless gr.attribute_wildcard.nil?
              if complete_wild.nil?
                complete_wild = gr.attribute_wildcard
              else
                unless created
                  # Copy the first encountered wildcard as context, except for the
                  # annotation. Although the complete wildcard might not correspond to any
                  # node in the schema, we will anchor it on the node of the owner component.
                  tmp_wild = add_wildcard(pctxt, pctxt.schema,
                    XML_SCHEMA_TYPE_ANY_ATTRIBUTE, get_component_node(item))
                  return [-1, complete_wild] if tmp_wild.nil?
                  return [-1, complete_wild] if clone_wildcard_ns_constraints(pctxt,
                    tmp_wild, complete_wild) == -1

                  tmp_wild.process_contents = complete_wild.process_contents
                  complete_wild = tmp_wild
                  created = true
                end

                if intersect_wildcards(pctxt, complete_wild, gr.attribute_wildcard) == -1
                  return [-1, complete_wild]
                end
              end
            end
            # Just remove the reference if the referenced group does not contain any
            # attribute uses.
            sublist = gr.attr_uses
            if sublist.nil? || sublist.nb_items == 0
              items.delete_at(i)
              next
            end
            # Add the attribute uses.
            items[i] = sublist.items[0]
            if sublist.nb_items != 1
              j = 1
              while j < sublist.nb_items
                i += 1
                items.insert(i, sublist.items[j])
                j += 1
              end
            end
          end
          i += 1
        end
        # Handle pointless prohibitions of declared attributes.
        if prohibs && prohibs.nb_items != 0 && list.nb_items != 0
          i = prohibs.nb_items - 1
          while i >= 0
            prohib = prohibs.items[i]
            items.each do |u|
              next unless prohib.name == u.attr_decl.name &&
                prohib.target_namespace == u.attr_decl.target_namespace

              custom_warning(pctxt,
                ErrCode::SCHEMAP_WARN_ATTR_POINTLESS_PROH,
                prohib.node, nil,
                "Skipping pointless attribute use prohibition " \
                "'%s', since a corresponding attribute use " \
                "exists already in the type definition",
                format_q_name(prohib.target_namespace, prohib.name),
                nil, nil)
              # Remove the prohibition.
              prohibs.items.delete_at(i)
              break
            end
            i -= 1
          end
        end
        [0, complete_wild]
      end

      # xmlSchemaAttributeGroupExpandRefs
      # Computation of: {attribute uses} property, {attribute wildcard} property
      def attribute_group_expand_refs(pctxt, attr_gr)
        return 0 if attr_gr.attr_uses.nil? ||
          (attr_gr.flags & XML_SCHEMAS_ATTRGROUP_WILDCARD_BUILDED) != 0

        attr_gr.flags |= XML_SCHEMAS_ATTRGROUP_WILDCARD_BUILDED
        ret, attr_gr.attribute_wildcard = expand_attribute_group_refs(pctxt, attr_gr,
          attr_gr.attribute_wildcard, attr_gr.attr_uses, nil)
        return -1 if ret == -1

        0
      end

      # xmlSchemaCheckAGPropsCorrect
      # Schema Component Constraint: Attribute Group Definition Properties Correct
      # (ag-props-correct)
      def check_ag_props_correct(pctxt, attr_gr)
        # SPEC ag-props-correct (1) ...
        if attr_gr.attr_uses && attr_gr.attr_uses.nb_items > 1
          uses = attr_gr.attr_uses
          has_id = false
          i = uses.nb_items - 1
          while i >= 0
            use = uses.items[i]
            removed = false
            # SPEC ag-props-correct (2) "Two distinct members of the {attribute uses} must
            # not have {attribute declaration}s both of whose {name}s match and whose
            # {target namespace}s are identical."
            if i > 0
              j = i - 1
              while j >= 0
                tmp = uses.items[j]
                if use.attr_decl.name == tmp.attr_decl.name &&
                    use.attr_decl.target_namespace == tmp.attr_decl.target_namespace
                  custom_err(pctxt, ErrCode::SCHEMAP_AG_PROPS_CORRECT,
                    attr_gr.node, attr_gr,
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
              # SPEC ag-props-correct (3) "Two distinct members of the {attribute uses} must
              # not have {attribute declaration}s both of whose {type definition}s are or are
              # derived from ID."
              if !use.attr_decl.subtypes.nil? &&
                  is_derived_from_built_in_type(use.attr_decl.subtypes, XML_SCHEMAS_ID) != 0
                if has_id
                  custom_err(pctxt, ErrCode::SCHEMAP_AG_PROPS_CORRECT,
                    attr_gr.node, attr_gr,
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

      # xmlSchemaResolveAttrGroupReferences
      # Resolves references to attribute group definitions.
      def resolve_attr_group_references(ref, ctxt)
        return 0 unless ref.item.nil?

        group = get_attribute_group(ctxt.schema, ref.name, ref.target_namespace)
        if group.nil?
          p_res_comp_attr_err(ctxt, ErrCode::SCHEMAP_SRC_RESOLVE,
            nil, ref.node,
            "ref", ref.name, ref.target_namespace,
            ref.item_type, nil)
          return ctxt.err
        end
        ref.item = group
        0
      end

      # xmlSchemaCheckAttrPropsCorrect
      # Schema Component Constraint: Attribute Declaration Properties Correct
      # (a-props-correct). Validates the value constraints of an attribute declaration/use.
      def check_attr_props_correct(pctxt, attr)
        # SPEC a-props-correct (1) ...
        return 0 if attr.subtypes.nil?

        unless attr.def_value.nil?
          # SPEC a-props-correct (3) "If the {type definition} is or is derived from ID then
          # there must not be a {value constraint}."
          if is_derived_from_built_in_type(attr.subtypes, XML_SCHEMAS_ID) != 0
            custom_err(pctxt, ErrCode::SCHEMAP_A_PROPS_CORRECT_3,
              nil, attr,
              "Value constraints are not allowed if the type definition " \
              "is or is derived from xs:ID",
              nil, nil)
            return pctxt.err
          end
          # SPEC a-props-correct (2) "if there is a {value constraint}, the canonical lexical
          # representation of its value must be `valid` with respect to the {type
          # definition} as defined in String Valid ($3.14.4)."
          ret, attr.def_val = v_check_cvc_simple_type(pctxt, attr.node, attr.subtypes,
            attr.def_value, true, 1, 1, 0)
          if ret != 0
            if ret < 0
              internal_err(pctxt, "xmlSchemaCheckAttrPropsCorrect",
                "calling xmlSchemaVCheckCVCSimpleType()")
              return -1
            end
            custom_err(pctxt, ErrCode::SCHEMAP_A_PROPS_CORRECT_2,
              nil, attr,
              "The value of the value constraint is not valid",
              nil, nil)
            return pctxt.err
          end
        end
        0
      end

      # xmlSchemaCheckSubstGroupCircular
      def check_subst_group_circular(elem_decl, ancestor)
        head = ancestor.ref_decl
        return nil if head.nil?
        return ancestor if head.equal?(elem_decl)
        return nil if (head.flags & XML_SCHEMAS_ELEM_CIRCULAR) != 0

        head.flags |= XML_SCHEMAS_ELEM_CIRCULAR
        ret = check_subst_group_circular(elem_decl, head)
        head.flags ^= XML_SCHEMAS_ELEM_CIRCULAR
        ret
      end

      # xmlSchemaCheckElemPropsCorrect
      # Schema Component Constraint: Element Declaration Properties Correct (e-props-correct)
      def check_elem_props_correct(pctxt, elem_decl)
        ret = 0
        type_def = elem_decl.subtypes
        # SPEC (1) ...
        unless elem_decl.ref_decl.nil?
          head = elem_decl.ref_decl

          check_element_decl_component(head, pctxt)
          # SPEC (3) "If there is a non-`absent` {substitution group affiliation}, then
          # {scope} must be global."
          if (elem_decl.flags & XML_SCHEMAS_ELEM_GLOBAL) == 0
            p_custom_err(pctxt, ErrCode::SCHEMAP_E_PROPS_CORRECT_3,
              elem_decl, nil,
              "Only global element declarations can have a " \
              "substitution group affiliation", nil)
            ret = ErrCode::SCHEMAP_E_PROPS_CORRECT_3
          end
          # TODO: SPEC (6) "Circular substitution groups are disallowed."
          circ = if head.equal?(elem_decl)
            head
          elsif !head.ref_decl.nil?
            check_subst_group_circular(head, head)
          end
          unless circ.nil?
            p_custom_err_ext(pctxt, ErrCode::SCHEMAP_E_PROPS_CORRECT_6,
              circ, nil,
              "The element declaration '%s' defines a circular " \
              "substitution group to element declaration '%s'",
              get_component_q_name(circ),
              get_component_q_name(head),
              nil)
            ret = ErrCode::SCHEMAP_E_PROPS_CORRECT_6
          end
          # SPEC (4) "If there is a {substitution group affiliation}, the {type definition}
          # of the element declaration must be validly derived from the {type definition}
          # of the {substitution group affiliation}, given the value of the {substitution
          # group exclusions} of the {substitution group affiliation}, ..."
          unless type_def.equal?(elem_decl.ref_decl.subtypes)
            set = 0
            set |= SUBSET_EXTENSION if (head.flags & XML_SCHEMAS_ELEM_FINAL_EXTENSION) != 0
            set |= SUBSET_RESTRICTION if (head.flags & XML_SCHEMAS_ELEM_FINAL_RESTRICTION) != 0

            if check_cos_derived_ok(pctxt, type_def, head.subtypes, set) != 0
              ret = ErrCode::SCHEMAP_E_PROPS_CORRECT_4
              p_custom_err_ext(pctxt, ErrCode::SCHEMAP_E_PROPS_CORRECT_4,
                elem_decl, nil,
                "The type definition '%s' was " \
                "either rejected by the substitution group " \
                "affiliation '%s', or not validly derived from its type " \
                "definition '%s'",
                get_component_q_name(type_def),
                get_component_q_name(head),
                get_component_q_name(head.subtypes))
            end
          end
        end
        # SPEC (5) "If the {type definition} or {type definition}'s {content type} is or is
        # derived from ID then there must not be a {value constraint}."
        if !elem_decl.value.nil? &&
            ((wxs_is_simple(type_def) &&
              is_derived_from_built_in_type(type_def, XML_SCHEMAS_ID) != 0) ||
             (wxs_is_complex(type_def) && wxs_has_simple_content(type_def) &&
              is_derived_from_built_in_type(type_def.content_type_def, XML_SCHEMAS_ID) != 0))
          ret = ErrCode::SCHEMAP_E_PROPS_CORRECT_5
          p_custom_err(pctxt, ErrCode::SCHEMAP_E_PROPS_CORRECT_5,
            elem_decl, nil,
            "The type definition (or type definition's content type) is or " \
            "is derived from ID; value constraints are not allowed in " \
            "conjunction with such a type definition", nil)
        elsif !elem_decl.value.nil?
          node = nil
          # SPEC (2) "If there is a {value constraint}, the canonical lexical representation
          # of its value must be `valid` with respect to the {type definition} as defined in
          # Element Default Valid (Immediate) ($3.3.6)."
          if type_def.nil?
            p_err(pctxt, elem_decl.node, ErrCode::SCHEMAP_INTERNAL,
              "Internal error: xmlSchemaCheckElemPropsCorrect, " \
              "type is missing... skipping validation of " \
              "the value constraint", nil, nil)
            return -1
          end
          unless elem_decl.node.nil?
            node = if (elem_decl.flags & XML_SCHEMAS_ELEM_FIXED) != 0
              Tree.has_prop(elem_decl.node, "fixed")
            else
              Tree.has_prop(elem_decl.node, "default")
            end
          end
          vcret, elem_decl.def_val = parse_check_cos_valid_default(pctxt, node,
            type_def, elem_decl.value, true)
          if vcret != 0
            if vcret < 0
              internal_err(pctxt, "xmlSchemaElemCheckValConstr",
                "failed to validate the value constraint of an " \
                "element declaration")
              return -1
            end
            return vcret
          end
        end
        ret
      end

      # xmlSchemaCheckElemSubstGroup
      # Schema Component Constraint: Substitution Group (cos-equiv-class)
      def check_elem_subst_group(ctxt, elem_decl)
        # SPEC (1) "Its {abstract} is false."
        return if elem_decl.ref_decl.nil? || (elem_decl.flags & XML_SCHEMAS_ELEM_ABSTRACT) != 0

        # SPEC (2) "It is validly substitutable for HEAD subject to HEAD's {disallowed
        # substitutions} as the blocking constraint, as defined in Substitution Group OK
        # (Transitive) ($3.3.6)."
        head = elem_decl.ref_decl
        while head
          set = 0
          meth_set = 0
          # The blocking constraints.
          if (head.flags & XML_SCHEMAS_ELEM_BLOCK_SUBSTITUTION) != 0
            head = head.ref_decl
            next
          end
          head_type = head.subtypes
          type = elem_decl.subtypes
          unless head_type.equal?(type)
            set |= XML_SCHEMAS_TYPE_BLOCK_RESTRICTION if (head.flags & XML_SCHEMAS_ELEM_BLOCK_RESTRICTION) != 0
            set |= XML_SCHEMAS_TYPE_BLOCK_EXTENSION if (head.flags & XML_SCHEMAS_ELEM_BLOCK_EXTENSION) != 0
            # SPEC: Substitution Group OK (Transitive) (2.3) ...
            # The set of all {derivation method}s involved in the derivation
            while !type.nil? && !type.equal?(head_type) && !type.equal?(type.base_type)
              if wxs_is_extension(type) && (meth_set & XML_SCHEMAS_TYPE_BLOCK_RESTRICTION) == 0
                meth_set |= XML_SCHEMAS_TYPE_BLOCK_EXTENSION
              end
              if wxs_is_restriction(type) && (meth_set & XML_SCHEMAS_TYPE_BLOCK_RESTRICTION) == 0
                meth_set |= XML_SCHEMAS_TYPE_BLOCK_RESTRICTION
              end
              type = type.base_type
            end
            # The {prohibited substitutions} of all intermediate types + the head's type.
            type = elem_decl.subtypes.base_type
            while type
              if wxs_is_complex(type)
                if (type.flags & XML_SCHEMAS_TYPE_BLOCK_EXTENSION) != 0 &&
                    (set & XML_SCHEMAS_TYPE_BLOCK_EXTENSION) == 0
                  set |= XML_SCHEMAS_TYPE_BLOCK_EXTENSION
                end
                if (type.flags & XML_SCHEMAS_TYPE_BLOCK_RESTRICTION) != 0 &&
                    (set & XML_SCHEMAS_TYPE_BLOCK_RESTRICTION) == 0
                  set |= XML_SCHEMAS_TYPE_BLOCK_RESTRICTION
                end
              else
                break
              end
              break if type.equal?(head_type)

              type = type.base_type
            end
            if set != 0 &&
                (((set & XML_SCHEMAS_TYPE_BLOCK_EXTENSION) != 0 &&
                  (meth_set & XML_SCHEMAS_TYPE_BLOCK_EXTENSION) != 0) ||
                 ((set & XML_SCHEMAS_TYPE_BLOCK_RESTRICTION) != 0 &&
                  (meth_set & XML_SCHEMAS_TYPE_BLOCK_RESTRICTION) != 0))
              head = head.ref_decl
              next
            end
          end
          # add_member:
          add_element_substitution_member(ctxt, head, elem_decl)
          head.flags |= XML_SCHEMAS_ELEM_SUBST_GROUP_HEAD
          head = head.ref_decl
        end
      end

      # xmlSchemaCheckElementDeclConsistent: only compiled with WXS_ELEM_DECL_CONS_ENABLED
      # (off by default), so not ported.

      # xmlSchemaCheckElementDeclComponent
      # Validates the value constraints of an element declaration. Adds substitution group
      # members.
      def check_element_decl_component(elem_decl, ctxt)
        return if elem_decl.nil?
        return if (elem_decl.flags & XML_SCHEMAS_ELEM_INTERNAL_CHECKED) != 0

        elem_decl.flags |= XML_SCHEMAS_ELEM_INTERNAL_CHECKED
        if check_elem_props_correct(ctxt, elem_decl) == 0
          # Adds substitution group members.
          check_elem_subst_group(ctxt, elem_decl)
        end
      end
    end
  end
end
