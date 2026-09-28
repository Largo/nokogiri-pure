# frozen_string_literal: true

require_relative "structs"
require_relative "macros"
require_relative "common"

# Port of xmlschemas.c (2.13.9) lines ~19953-21530: remaining reference resolution
# (particles, attribute uses, attribute types, IDC keyrefs, prohibitions), attribute use
# constraints, redefinition checks, xmlSchemaAddComponents, the staged
# xmlSchemaFixupComponents driver, the public xmlSchemaParse entry point and the parser
# error-handler setters.
module Nokogiri
  module Pure
    module Schemas
      extend self

      # xmlSchemaResolveModelGroupParticleReferences
      # Resolves references of a model group's {particles} to model group definitions and to
      # element declarations.
      def resolve_model_group_particle_references(ctxt, mg)
        particle = mg.children
        while particle
          term = particle.children
          if term.nil? || term.type != XML_SCHEMA_EXTRA_QNAMEREF
            particle = particle.next
            next
          end
          ref = term
          # Resolve the reference. NULL the {term} by default.
          particle.children = nil

          ref_item = get_named_component(ctxt.schema, ref.item_type, ref.name,
            ref.target_namespace)
          if ref_item.nil?
            p_res_comp_attr_err(ctxt, ErrCode::SCHEMAP_SRC_RESOLVE,
              nil, get_component_node(particle), "ref", ref.name,
              ref.target_namespace, ref.item_type, nil)
            # TODO: remove the particle.
            particle = particle.next
            next
          end
          if ref_item.type == XML_SCHEMA_TYPE_GROUP
            if ref_item.children.nil?
              # TODO: remove the particle.
              particle = particle.next
              next
            end
            # NOTE that we will assign the model group definition itself to the "term" of
            # the particle. This will ease the check for circular model group definitions.
            if ref_item.children.type == XML_SCHEMA_TYPE_ALL
              # SPEC cos-all-limited (1) / (1.2)
              custom_err(ctxt,
                ErrCode::SCHEMAP_COS_ALL_LIMITED,
                get_component_node(particle), nil,
                "A model group definition is referenced, but " \
                "it contains an 'all' model group, which " \
                "cannot be contained by model groups",
                nil, nil)
              # TODO: remove the particle.
              particle = particle.next
              next
            end
            particle.children = ref_item
          else
            # TODO: Are referenced element declarations the only other components we expect
            # here?
            particle.children = ref_item
          end
          particle = particle.next
        end
      end

      # xmlSchemaAreValuesEqual
      def are_values_equal(x, y)
        while x
          # Same types.
          tx = Types.get_built_in_type(Types.get_val_type(x))
          ty = Types.get_built_in_type(Types.get_val_type(y))
          ptx = get_primitive_type(tx)
          pty = get_primitive_type(ty)
          # (1) / (2) ...
          return 0 unless ptx.equal?(pty)

          # We assume computed values to be normalized, so do a fast string comparison for
          # string based types.
          if ptx.built_in_type == XML_SCHEMAS_STRING || wxs_is_any_simple_type(ptx)
            return 0 unless Types.value_get_as_string(x) == Types.value_get_as_string(y)
          else
            ret = Types.compare_values_whtsp(x, XML_SCHEMA_WHITESPACE_PRESERVE,
              y, XML_SCHEMA_WHITESPACE_PRESERVE)
            return -1 if ret == -2
            return 0 if ret != 0
          end
          # Lists.
          x = Types.value_get_next(x)
          if !x.nil?
            y = Types.value_get_next(y)
            return 0 if y.nil?
          elsif !Types.value_get_next(y).nil?
            return 0
          else
            return 1
          end
        end
        0
      end

      # xmlSchemaResolveAttrUseReferences
      # Resolves the referenced attribute declaration.
      def resolve_attr_use_references(ause, ctxt)
        return -1 if ctxt.nil? || ause.nil?
        return 0 if ause.attr_decl.nil? || ause.attr_decl.type != XML_SCHEMA_EXTRA_QNAMEREF

        ref = ause.attr_decl
        ause.attr_decl = get_attribute_decl(ctxt.schema, ref.name, ref.target_namespace)
        if ause.attr_decl.nil?
          p_res_comp_attr_err(ctxt, ErrCode::SCHEMAP_SRC_RESOLVE,
            ause, ause.node,
            "ref", ref.name, ref.target_namespace,
            XML_SCHEMA_TYPE_ATTRIBUTE, nil)
          return ctxt.err
        end
        0
      end

      # xmlSchemaCheckAttrUsePropsCorrect
      # Schema Component Constraint: Attribute Use Correct (au-props-correct)
      def check_attr_use_props_correct(ctxt, use)
        return -1 if ctxt.nil? || use.nil?
        return 0 if use.def_value.nil? || use.attr_decl.nil? ||
          use.attr_decl.type != XML_SCHEMA_TYPE_ATTRIBUTE

        decl = use.attr_decl
        # SPEC au-props-correct (1) ...
        if !decl.def_value.nil? && (decl.flags & XML_SCHEMAS_ATTR_FIXED) != 0 &&
            (use.flags & XML_SCHEMA_ATTR_USE_FIXED) == 0
          p_custom_err(ctxt, ErrCode::SCHEMAP_AU_PROPS_CORRECT_2,
            use, nil,
            "The attribute declaration has a 'fixed' value constraint " \
            ", thus the attribute use must also have a 'fixed' value " \
            "constraint",
            nil)
          return ctxt.err
        end
        # Compute and check the value constraint's value.
        if !use.def_val.nil? && !decl.subtypes.nil?
          # SPEC a-props-correct (3)
          if is_derived_from_built_in_type(decl.subtypes, XML_SCHEMAS_ID) != 0
            custom_err(ctxt, ErrCode::SCHEMAP_AU_PROPS_CORRECT,
              nil, use,
              "Value constraints are not allowed if the type definition " \
              "is or is derived from xs:ID",
              nil, nil)
            return ctxt.err
          end

          ret, use.def_val = v_check_cvc_simple_type(ctxt, use.node, decl.subtypes,
            use.def_value, true, 1, 1, 0)
          if ret != 0
            if ret < 0
              internal_err(ctxt, "xmlSchemaCheckAttrUsePropsCorrect",
                "calling xmlSchemaVCheckCVCSimpleType()")
              return -1
            end
            custom_err(ctxt, ErrCode::SCHEMAP_AU_PROPS_CORRECT,
              nil, use,
              "The value of the value constraint is not valid",
              nil, nil)
            return ctxt.err
          end
        end
        # SPEC au-props-correct (2) "If the {attribute declaration} has a fixed {value
        # constraint}, then if the attribute use itself has a {value constraint}, it must
        # also be fixed and its value must match that of the {attribute declaration}'s
        # {value constraint}."
        # NOTE: libxml2 tests XML_SCHEMA_ATTR_USE_FIXED (1<<0) on the *declaration's* flags
        # here; ported as is.
        if !decl.def_val.nil? && (decl.flags & XML_SCHEMA_ATTR_USE_FIXED) == 0
          if are_values_equal(use.def_val, decl.def_val) == 0
            p_custom_err(ctxt, ErrCode::SCHEMAP_AU_PROPS_CORRECT_2,
              use, nil,
              "The 'fixed' value constraint of the attribute use " \
              "must match the attribute declaration's value " \
              "constraint '%s'",
              decl.def_value)
          end
          return ctxt.err
        end
        0
      end

      # xmlSchemaResolveAttrTypeReferences
      # Resolves the referenced type definition component.
      def resolve_attr_type_references(item, ctxt)
        # The simple type definition corresponding to the <simpleType> element information
        # item in the [children], if present, otherwise the simple type definition
        # `resolved` to by the `actual value` of the type [attribute], if present, otherwise
        # the `simple ur-type definition`.
        return 0 if (item.flags & XML_SCHEMAS_ATTR_INTERNAL_RESOLVED) != 0

        item.flags |= XML_SCHEMAS_ATTR_INTERNAL_RESOLVED
        return 0 unless item.subtypes.nil?

        if !item.type_name.nil?
          type = get_type(ctxt.schema, item.type_name, item.type_ns)
          if type.nil? || !wxs_is_simple(type)
            p_res_comp_attr_err(ctxt, ErrCode::SCHEMAP_SRC_RESOLVE,
              item, item.node,
              "type", item.type_name, item.type_ns,
              XML_SCHEMA_TYPE_SIMPLE, nil)
            return ctxt.err
          else
            item.subtypes = type
          end
        else
          # The type defaults to the xs:anySimpleType.
          item.subtypes = Types.get_built_in_type(XML_SCHEMAS_ANYSIMPLETYPE)
        end
        0
      end

      # xmlSchemaResolveIDCKeyReferences
      # Resolve keyRef references to key/unique IDCs.
      # Schema Component Constraint: Identity-constraint Definition Properties Correct
      # (c-props-correct)
      def resolve_idc_key_references(idc, pctxt)
        return 0 if idc.type != XML_SCHEMA_TYPE_IDC_KEYREF

        unless idc.ref.name.nil?
          idc.ref.item = get_idc(pctxt.schema, idc.ref.name, idc.ref.target_namespace)
          if idc.ref.item.nil?
            # TODO: It is actually not an error to fail to resolve at this stage. BUT we
            # need to be that strict!
            p_res_comp_attr_err(pctxt, ErrCode::SCHEMAP_SRC_RESOLVE,
              idc, idc.node,
              "refer", idc.ref.name,
              idc.ref.target_namespace,
              XML_SCHEMA_TYPE_IDC_KEY, nil)
            return pctxt.err
          elsif idc.ref.item.type == XML_SCHEMA_TYPE_IDC_KEYREF
            # SPEC c-props-correct (1)
            custom_err(pctxt, ErrCode::SCHEMAP_C_PROPS_CORRECT,
              nil, idc,
              "The keyref references a keyref",
              nil, nil)
            idc.ref.item = nil
            return pctxt.err
          elsif idc.nb_fields != idc.ref.item.nb_fields
            refer = idc.ref.item
            # SPEC c-props-correct(2) "If the {identity-constraint category} is keyref, the
            # cardinality of the {fields} must equal that of the {fields} of the {referenced
            # key}.
            custom_err(pctxt, ErrCode::SCHEMAP_C_PROPS_CORRECT,
              nil, idc,
              "The cardinality of the keyref differs from the " \
              "cardinality of the referenced key/unique '%s'",
              format_q_name(refer.target_namespace, refer.name),
              nil)
            return pctxt.err
          end
        end
        0
      end

      # xmlSchemaResolveAttrUseProhibReferences
      def resolve_attr_use_prohib_references(prohib, pctxt)
        if get_attribute_decl(pctxt.schema, prohib.name, prohib.target_namespace).nil?
          p_res_comp_attr_err(pctxt, ErrCode::SCHEMAP_SRC_RESOLVE,
            nil, prohib.node,
            "ref", prohib.name, prohib.target_namespace,
            XML_SCHEMA_TYPE_ATTRIBUTE, nil)
          return ErrCode::SCHEMAP_SRC_RESOLVE
        end
        0
      end

      # xmlSchemaCheckSRCRedefineFirst
      def check_src_redefine_first(pctxt)
        err = 0
        redef = pctxt.constructor.redefs

        return 0 if redef.nil?

        while redef
          item = redef.item
          # First try to locate the redefined component in the schema graph starting with
          # the redefined schema.
          prev = find_redef_comp_in_graph(redef.target_bucket, item.type,
            redef.ref_name, redef.ref_target_ns)
          if prev.nil?
            # SPEC src-redefine: (6.2.1) / (7.2.1) ...
            node = if redef.reference
              get_component_node(redef.reference)
            else
              get_component_node(item)
            end
            custom_err(pctxt,
              ErrCode::SCHEMAP_SRC_REDEFINE, node, nil,
              "The %s '%s' to be redefined could not be found in " \
              "the redefined schema",
              get_component_type_str(item),
              format_q_name(redef.ref_target_ns, redef.ref_name))
            err = pctxt.err
            redef = redef.next
            next
          end
          # TODO: Obtaining and setting the redefinition state is really clumsy.
          was_redefined = false
          case item.type
          when XML_SCHEMA_TYPE_COMPLEX, XML_SCHEMA_TYPE_SIMPLE
            if (prev.flags & XML_SCHEMAS_TYPE_REDEFINED) != 0
              was_redefined = true
            else
              # Mark it as redefined.
              prev.flags |= XML_SCHEMAS_TYPE_REDEFINED
              # Assign the redefined type to the base type of the redefining type.
              item.base_type = prev
            end
          when XML_SCHEMA_TYPE_GROUP
            if (prev.flags & XML_SCHEMA_MODEL_GROUP_DEF_REDEFINED) != 0
              was_redefined = true
            else
              # Mark it as redefined.
              prev.flags |= XML_SCHEMA_MODEL_GROUP_DEF_REDEFINED
              unless redef.reference.nil?
                # Overwrite the QName-reference with the referenced model group def.
                redef.reference.children = prev
              end
              redef.target = prev
            end
          when XML_SCHEMA_TYPE_ATTRIBUTEGROUP
            if (prev.flags & XML_SCHEMAS_ATTRGROUP_REDEFINED) != 0
              was_redefined = true
            else
              prev.flags |= XML_SCHEMAS_ATTRGROUP_REDEFINED
              if !redef.reference.nil?
                # Assign the redefined attribute group to the QName-reference component.
                # This is the easy case, since we will just expand the redefined group.
                redef.reference.item = prev
                redef.target = nil
              else
                # This is the complicated case: we need to apply src-redefine (7.2.2) at a
                # later stage, i.e. when attribute group references have been expanded and
                # simple types have been fixed.
                redef.target = prev
              end
            end
          else
            internal_err(pctxt, "xmlSchemaResolveRedefReferences",
              "Unexpected redefined component type")
            return -1
          end
          if was_redefined
            node = if redef.reference
              get_component_node(redef.reference)
            else
              get_component_node(redef.item)
            end
            custom_err(pctxt,
              ErrCode::SCHEMAP_SRC_REDEFINE,
              node, nil,
              "The referenced %s was already redefined. Multiple " \
              "redefinition of the same component is not supported",
              get_component_designation(prev),
              nil)
            err = pctxt.err
            redef = redef.next
            next
          end
          redef = redef.next
        end
        err
      end

      # xmlSchemaCheckSRCRedefineSecond
      def check_src_redefine_second(pctxt)
        err = 0
        redef = pctxt.constructor.redefs

        return 0 if redef.nil?

        while redef
          if redef.target.nil?
            redef = redef.next
            next
          end
          item = redef.item

          case item.type
          when XML_SCHEMA_TYPE_SIMPLE, XML_SCHEMA_TYPE_COMPLEX
            # Since the spec wants the {name} of the redefined type to be 'absent', we'll
            # NULL it.
            redef.target.name = nil
          when XML_SCHEMA_TYPE_GROUP
            # URGENT TODO: SPEC src-redefine: (6.2.2)
            nil
          when XML_SCHEMA_TYPE_ATTRIBUTEGROUP
            # SPEC src-redefine: (7.2.2) ...
            err = check_derivation_ok_restriction2to4(pctxt,
              XML_SCHEMA_ACTION_REDEFINE,
              item, redef.target,
              item.attr_uses,
              redef.target.attr_uses,
              item.attribute_wildcard,
              redef.target.attribute_wildcard)
            return -1 if err == -1
          end
          redef = redef.next
        end
        0
      end

      # Maps a global component type to the xmlSchema hash slot (WXS_GET_GLOBAL_HASH)
      GLOBAL_HASH_SLOTS = {
        XML_SCHEMA_TYPE_COMPLEX => :type_decl,
        XML_SCHEMA_TYPE_SIMPLE => :type_decl,
        XML_SCHEMA_TYPE_ELEMENT => :elem_decl,
        XML_SCHEMA_TYPE_ATTRIBUTE => :attr_decl,
        XML_SCHEMA_TYPE_GROUP => :group_decl,
        XML_SCHEMA_TYPE_ATTRIBUTEGROUP => :attrgrp_decl,
        XML_SCHEMA_TYPE_IDC_KEY => :idc_def,
        XML_SCHEMA_TYPE_IDC_UNIQUE => :idc_def,
        XML_SCHEMA_TYPE_IDC_KEYREF => :idc_def,
        XML_SCHEMA_TYPE_NOTATION => :nota_decl
      }.freeze

      # xmlSchemaAddComponents
      def add_components(pctxt, bucket)
        # Add global components to the schema's hash tables. This is the place where
        # duplicate components will be detected.
        return -1 if bucket.nil?
        return 0 if (bucket.flags & XML_SCHEMA_BUCKET_COMPS_ADDED) != 0

        bucket.flags |= XML_SCHEMA_BUCKET_COMPS_ADDED

        # WXS_GET_GLOBAL_HASH: the schema of the import/main bucket
        schema = if wxs_is_bucket_impmain(bucket.type)
          bucket.schema
        else
          bucket.owner_import.schema
        end

        globals = bucket.globals ? bucket.globals.items : []
        i = 0
        while i < globals.size
          item = globals[i]
          i += 1
          case item.type
          when XML_SCHEMA_TYPE_COMPLEX, XML_SCHEMA_TYPE_SIMPLE
            next if (item.flags & XML_SCHEMAS_TYPE_REDEFINED) != 0
          when XML_SCHEMA_TYPE_GROUP
            next if (item.flags & XML_SCHEMA_MODEL_GROUP_DEF_REDEFINED) != 0
          when XML_SCHEMA_TYPE_ATTRIBUTEGROUP
            next if (item.flags & XML_SCHEMAS_ATTRGROUP_REDEFINED) != 0
          when XML_SCHEMA_TYPE_ELEMENT, XML_SCHEMA_TYPE_ATTRIBUTE,
            XML_SCHEMA_TYPE_IDC_KEY, XML_SCHEMA_TYPE_IDC_UNIQUE, XML_SCHEMA_TYPE_IDC_KEYREF,
            XML_SCHEMA_TYPE_NOTATION
            nil
          else
            internal_err(pctxt, "xmlSchemaAddComponents", "Unexpected global component type")
            next
          end
          slot = GLOBAL_HASH_SLOTS[item.type]
          name = item.name
          table = schema.public_send(slot)
          if table.nil?
            table = {}
            schema.public_send(:"#{slot}=", table)
          end
          # xmlHashAddEntry fails for an existing key (and for a NULL name)
          if name.nil? || table.key?(name)
            custom_err(pctxt,
              ErrCode::SCHEMAP_REDEFINED_TYPE,
              get_component_node(item),
              item,
              "A global %s '%s' does already exist",
              get_component_type_str(item),
              get_component_q_name(item))
          else
            table[name] = item
          end
        end
        # Process imported/included schemas.
        rel = bucket.relations
        while rel
          if !rel.bucket.nil? && (rel.bucket.flags & XML_SCHEMA_BUCKET_COMPS_ADDED) == 0
            return -1 if add_components(pctxt, rel.bucket) == -1
          end
          rel = rel.next
        end
        0
      end

      # xmlSchemaFixupComponents
      # The big staged driver: the stage order determines the error order.
      def fixup_components(pctxt, root_bucket)
        con = pctxt.constructor
        oldbucket = con.bucket

        return 0 if con.pending.nil? || con.pending.nb_items == 0

        ret = 0
        # Since xmlSchemaFixupComplexType() will create new particles (local components),
        # and those particle components need a bucket on the constructor, we'll assure
        # here that the constructor has a bucket.
        con.bucket = root_bucket if con.bucket.nil?

        # TODO: SPEC (src-redefine) (6.2) ...
        check_src_redefine_first(pctxt)

        # Add global components to the schemata's hash tables.
        add_components(pctxt, root_bucket)

        pctxt.ctxt_type = nil
        items = con.pending.items
        nb_items = items.size

        ret = catch(:fixup_exit) do
          # FIXHFAILURE
          fixhfailure = -> { throw :fixup_exit, -1 if pctxt.err == ErrCode::SCHEMAP_INTERNAL }
          exit_error = -> { throw :fixup_exit, pctxt.err }

          # Resolve references of..
          # 1. element declarations 2. simple/complex types 3. attributes declarations and
          # attribute uses 4. attribute group references 5. particles 6. IDC key-references
          # 7. Attribute prohibitions which had a "ref" attribute.
          i = 0
          while i < nb_items
            item = items[i]
            case item.type
            when XML_SCHEMA_TYPE_ELEMENT
              resolve_element_references(item, pctxt)
              fixhfailure.()
            when XML_SCHEMA_TYPE_COMPLEX, XML_SCHEMA_TYPE_SIMPLE
              resolve_type_references(item, pctxt)
              fixhfailure.()
            when XML_SCHEMA_TYPE_ATTRIBUTE
              resolve_attr_type_references(item, pctxt)
              fixhfailure.()
            when XML_SCHEMA_TYPE_ATTRIBUTE_USE
              resolve_attr_use_references(item, pctxt)
              fixhfailure.()
            when XML_SCHEMA_EXTRA_QNAMEREF
              if item.item_type == XML_SCHEMA_TYPE_ATTRIBUTEGROUP
                resolve_attr_group_references(item, pctxt)
              end
              fixhfailure.()
            when XML_SCHEMA_TYPE_SEQUENCE, XML_SCHEMA_TYPE_CHOICE, XML_SCHEMA_TYPE_ALL
              resolve_model_group_particle_references(pctxt, item)
              fixhfailure.()
            when XML_SCHEMA_TYPE_IDC_KEY, XML_SCHEMA_TYPE_IDC_UNIQUE, XML_SCHEMA_TYPE_IDC_KEYREF
              resolve_idc_key_references(item, pctxt)
              fixhfailure.()
            when XML_SCHEMA_EXTRA_ATTR_USE_PROHIB
              # Handle attribute prohibition which had a "ref" attribute.
              resolve_attr_use_prohib_references(item, pctxt)
              fixhfailure.()
            end
            i += 1
          end
          exit_error.() if pctxt.nberrors != 0

          # Now that all references are resolved we can check for circularity of...
          # 1. the base axis of type definitions 2. nested model group definitions
          # 3. nested attribute group definitions
          i = 0
          while i < nb_items
            item = items[i]
            # Let's better stop on the first error here.
            case item.type
            when XML_SCHEMA_TYPE_COMPLEX, XML_SCHEMA_TYPE_SIMPLE
              check_type_def_circular(item, pctxt)
              fixhfailure.()
              exit_error.() if pctxt.nberrors != 0
            when XML_SCHEMA_TYPE_GROUP
              check_group_def_circular(item, pctxt)
              fixhfailure.()
              exit_error.() if pctxt.nberrors != 0
            when XML_SCHEMA_TYPE_ATTRIBUTEGROUP
              check_attr_group_circular(item, pctxt)
              fixhfailure.()
              exit_error.() if pctxt.nberrors != 0
            end
            i += 1
          end
          exit_error.() if pctxt.nberrors != 0

          # Model group definition references: set the 'term' of such particles to the model
          # group of the model group definition.
          i = 0
          while i < nb_items
            item = items[i]
            if item.type == XML_SCHEMA_TYPE_SEQUENCE || item.type == XML_SCHEMA_TYPE_CHOICE
              model_group_to_model_group_def_fixup(pctxt, item)
            end
            i += 1
          end
          exit_error.() if pctxt.nberrors != 0

          # Expand attribute group references of attribute group definitions.
          i = 0
          while i < nb_items
            item = items[i]
            if item.type == XML_SCHEMA_TYPE_ATTRIBUTEGROUP &&
                !wxs_attr_group_expanded(item) && wxs_attr_group_has_refs(item)
              attribute_group_expand_refs(pctxt, item)
              fixhfailure.()
            end
            i += 1
          end
          exit_error.() if pctxt.nberrors != 0

          # First compute the variety of simple types. This is needed as a separate step,
          # since otherwise we won't be able to detect circular union types in all cases.
          i = 0
          while i < nb_items
            item = items[i]
            if item.type == XML_SCHEMA_TYPE_SIMPLE && wxs_is_type_not_fixed_1(item)
              fixup_simple_type_stage_one(pctxt, item)
              fixhfailure.()
            end
            i += 1
          end
          exit_error.() if pctxt.nberrors != 0

          # Detect circular union types. Note that this needs the variety to be already
          # computed.
          i = 0
          while i < nb_items
            item = items[i]
            if item.type == XML_SCHEMA_TYPE_SIMPLE && !item.member_types.nil?
              check_union_type_def_circular(pctxt, item)
              fixhfailure.()
            end
            i += 1
          end
          exit_error.() if pctxt.nberrors != 0

          # Do the complete type fixup for simple types.
          i = 0
          while i < nb_items
            item = items[i]
            if item.type == XML_SCHEMA_TYPE_SIMPLE && wxs_is_type_not_fixed(item)
              fixup_simple_type_stage_two(pctxt, item)
              fixhfailure.()
            end
            i += 1
          end
          exit_error.() if pctxt.nberrors != 0

          # Apply constraints for attribute declarations.
          i = 0
          while i < nb_items
            item = items[i]
            if item.type == XML_SCHEMA_TYPE_ATTRIBUTE
              check_attr_props_correct(pctxt, item)
              fixhfailure.()
            end
            i += 1
          end
          exit_error.() if pctxt.nberrors != 0

          # Apply constraints for attribute uses.
          i = 0
          while i < nb_items
            item = items[i]
            if item.type == XML_SCHEMA_TYPE_ATTRIBUTE_USE && !item.def_value.nil?
              check_attr_use_props_correct(pctxt, item)
              fixhfailure.()
            end
            i += 1
          end
          exit_error.() if pctxt.nberrors != 0

          # Apply constraints for attribute group definitions.
          i = 0
          while i < nb_items
            item = items[i]
            if item.type == XML_SCHEMA_TYPE_ATTRIBUTEGROUP &&
                !item.attr_uses.nil? && item.attr_uses.nb_items > 1
              check_ag_props_correct(pctxt, item)
              fixhfailure.()
            end
            i += 1
          end
          exit_error.() if pctxt.nberrors != 0

          # Apply constraints for redefinitions.
          check_src_redefine_second(pctxt) unless pctxt.constructor.redefs.nil?
          exit_error.() if pctxt.nberrors != 0

          # Complex types are built and checked.
          i = 0
          while i < nb_items
            item = con.pending.items[i]
            if item.type == XML_SCHEMA_TYPE_COMPLEX && wxs_is_type_not_fixed(item)
              fixup_complex_type(pctxt, item)
              fixhfailure.()
            end
            i += 1
          end
          exit_error.() if pctxt.nberrors != 0

          # The list could have changed, since xmlSchemaFixupComplexType() will create
          # particles and model groups in some cases.
          items = con.pending.items
          nb_items = items.size

          # Apply some constraints for element declarations.
          i = 0
          while i < nb_items
            item = items[i]
            if item.type == XML_SCHEMA_TYPE_ELEMENT &&
                (item.flags & XML_SCHEMAS_ELEM_INTERNAL_CHECKED) == 0
              check_element_decl_component(item, pctxt)
              fixhfailure.()
            end
            i += 1
          end
          exit_error.() if pctxt.nberrors != 0

          # Finally we can build the automaton from the content model of complex types.
          i = 0
          while i < nb_items
            item = items[i]
            build_content_model(item, pctxt) if item.type == XML_SCHEMA_TYPE_COMPLEX
            i += 1
          end
          exit_error.() if pctxt.nberrors != 0

          # URGENT TODO: cos-element-consistent
          0
        end

        # exit: Reset the constructor. This is needed for XSI acquisition, since those items
        # will be processed over and over again for every XSI if not cleared here.
        con.bucket = oldbucket
        con.pending.items.clear
        con.subst_groups = nil
        con.redefs = nil
        ret
      end

      # xmlSchemaParse (public)
      # parse a schema definition resource and build an internal XML Schema structure which
      # can be used to validate instances.
      # Returns the internal XML Schema structure built from the resource or NULL in case of
      # error
      def parse(ctxt)
        return nil if Types.init_types < 0
        return nil if ctxt.nil?

        # TODO: Init the context. Is this all we need?
        ctxt.nberrors = 0
        ctxt.err = 0
        ctxt.counter = 0

        main_schema = nil
        status = catch(:parse_exit) do
          # Create the *main* schema.
          main_schema = new_schema(ctxt)
          throw :parse_exit, :failure if main_schema.nil?

          # Create the schema constructor.
          if ctxt.constructor.nil?
            ctxt.constructor = construction_ctxt_create(ctxt.dict)
            throw :parse_exit, :failure if ctxt.constructor.nil?
            # Take ownership of the constructor to be able to free it.
            ctxt.owns_constructor = 1
          end
          ctxt.constructor.main_schema = main_schema
          # Locate and add the schema document.
          res, bucket = add_schema_doc(ctxt, XML_SCHEMA_SCHEMA_MAIN,
            ctxt.url, ctxt.doc, ctxt.buffer, ctxt.size, nil, nil, nil)
          throw :parse_exit, :failure if res == -1
          throw :parse_exit, :exit if res != 0

          if bucket.nil?
            # TODO: Error code, actually we failed to *locate* the schema.
            if ctxt.url
              custom_err(ctxt, ErrCode::SCHEMAP_FAILED_LOAD,
                nil, nil,
                "Failed to locate the main schema resource at '%s'",
                ctxt.url, nil)
            else
              custom_err(ctxt, ErrCode::SCHEMAP_FAILED_LOAD,
                nil, nil,
                "Failed to locate the main schema resource",
                nil, nil)
            end
            throw :parse_exit, :exit
          end
          # Then do the parsing for good.
          throw :parse_exit, :failure if parse_new_doc_with_context(ctxt, main_schema, bucket) == -1
          throw :parse_exit, :exit if ctxt.nberrors != 0

          main_schema.doc = bucket.doc
          main_schema.preserve = ctxt.preserve

          ctxt.schema = main_schema

          throw :parse_exit, :failure if fixup_components(ctxt, ctxt.constructor.main_bucket) == -1
          # TODO: This is not nice, since we cannot distinguish from the result if there
          # was an internal error or not.
          :exit
        end

        if status == :failure
          # exit_failure: Quite verbose, but should catch internal errors, which were not
          # communicated.
          main_schema = nil
          unless ctxt.constructor.nil?
            ctxt.constructor = nil
            ctxt.owns_constructor = 0
          end
          internal_err(ctxt, "xmlSchemaParse", "An internal error occurred")
          ctxt.schema = nil
          return nil
        end
        # exit:
        if ctxt.nberrors != 0
          main_schema = nil
          unless ctxt.constructor.nil?
            ctxt.constructor = nil
            ctxt.owns_constructor = 0
          end
        end
        ctxt.schema = nil
        main_schema
      end

      # xmlSchemaSetParserErrors (deprecated)
      # Set the callback functions used to handle errors for a validation context
      def set_parser_errors(ctxt, err, warn, ctx)
        return if ctxt.nil?

        ctxt.error = err
        ctxt.warning = warn
        ctxt.err_ctxt = ctx
        set_valid_errors(ctxt.vctxt, err, warn, ctx) unless ctxt.vctxt.nil?
      end

      # xmlSchemaSetParserStructuredErrors
      # Set the structured error callback
      def set_parser_structured_errors(ctxt, serror, ctx)
        return if ctxt.nil?

        ctxt.serror = serror
        ctxt.err_ctxt = ctx
        set_valid_structured_errors(ctxt.vctxt, serror, ctx) unless ctxt.vctxt.nil?
      end

      # xmlSchemaGetParserErrors
      # C: (ctxt, **err, **warn, **ctx) -> int
      # Ruby: get_parser_errors(ctxt) -> [ret, err, warn, ctx]
      def get_parser_errors(ctxt)
        return [-1, nil, nil, nil] if ctxt.nil?

        [0, ctxt.error, ctxt.warning, ctxt.err_ctxt]
      end

      FACET_TYPE_STRINGS = {
        XML_SCHEMA_FACET_PATTERN => "pattern",
        XML_SCHEMA_FACET_MAXEXCLUSIVE => "maxExclusive",
        XML_SCHEMA_FACET_MAXINCLUSIVE => "maxInclusive",
        XML_SCHEMA_FACET_MINEXCLUSIVE => "minExclusive",
        XML_SCHEMA_FACET_MININCLUSIVE => "minInclusive",
        XML_SCHEMA_FACET_WHITESPACE => "whiteSpace",
        XML_SCHEMA_FACET_ENUMERATION => "enumeration",
        XML_SCHEMA_FACET_LENGTH => "length",
        XML_SCHEMA_FACET_MAXLENGTH => "maxLength",
        XML_SCHEMA_FACET_MINLENGTH => "minLength",
        XML_SCHEMA_FACET_TOTALDIGITS => "totalDigits",
        XML_SCHEMA_FACET_FRACTIONDIGITS => "fractionDigits"
      }.freeze

      # xmlSchemaFacetTypeToString
      # Returns the char string representation of the facet type if the type is a facet and
      # an "Internal Error" string otherwise.
      def facet_type_to_string(type)
        FACET_TYPE_STRINGS.fetch(type, "Internal Error")
      end

      # xmlSchemaGetWhiteSpaceFacetValue
      def get_white_space_facet_value(type)
        # The normalization type can be changed only for types which are derived from
        # xsd:string.
        if type.type == XML_SCHEMA_TYPE_BASIC
          # Note that we assume a whitespace of preserve for anySimpleType.
          if type.built_in_type == XML_SCHEMAS_STRING ||
              type.built_in_type == XML_SCHEMAS_ANYSIMPLETYPE
            XML_SCHEMA_WHITESPACE_PRESERVE
          elsif type.built_in_type == XML_SCHEMAS_NORMSTRING
            XML_SCHEMA_WHITESPACE_REPLACE
          else
            # For all `atomic` datatypes other than string (and types `derived` by
            # `restriction` from it) the value of whiteSpace is fixed to collapse. Note that
            # this includes built-in list datatypes.
            XML_SCHEMA_WHITESPACE_COLLAPSE
          end
        elsif wxs_is_list(type)
          # For list types the facet "whiteSpace" is fixed to "collapse".
          XML_SCHEMA_WHITESPACE_COLLAPSE
        elsif wxs_is_union(type)
          XML_SCHEMA_WHITESPACE_UNKNOWN
        elsif wxs_is_atomic(type)
          if (type.flags & XML_SCHEMAS_TYPE_WHITESPACE_PRESERVE) != 0
            XML_SCHEMA_WHITESPACE_PRESERVE
          elsif (type.flags & XML_SCHEMAS_TYPE_WHITESPACE_REPLACE) != 0
            XML_SCHEMA_WHITESPACE_REPLACE
          else
            XML_SCHEMA_WHITESPACE_COLLAPSE
          end
        else
          -1
        end
      end
    end
  end
end
