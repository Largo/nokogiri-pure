# frozen_string_literal: true

require_relative "structs"
require_relative "common"
require_relative "macros"
require_relative "errors"

# Port of xmlschemas.c (libxml2 2.13.9) lines ~3330-5722: allocation functions, item lists,
# schema buckets, lookup functions (xmlSchemaGet*), component constructors (xmlSchemaAdd*),
# the substitution group table. Free functions are no-ops (garbage collection).
module Nokogiri
  module Pure
    module Schemas
      extend self

      # ------------------------------------------------------------------------------------
      # Allocation functions
      # ------------------------------------------------------------------------------------

      # xmlSchemaNewSchema
      def new_schema(ctxt)
        Schema.new(dict: ctxt&.dict)
      end

      # xmlSchemaNewFacet
      def new_facet
        SchemaFacet.new
      end

      # xmlSchemaNewAnnot
      def new_annot(_ctxt, node)
        SchemaAnnot.new(content: node)
      end

      # xmlSchemaItemListCreate
      def item_list_create
        SchemaItemList.new
      end

      # xmlSchemaItemListClear
      def item_list_clear(list)
        list.items = []
        nil
      end

      # xmlSchemaItemListAdd
      def item_list_add(list, item)
        list.items << item
        0
      end

      # xmlSchemaItemListAddSize
      def item_list_add_size(list, _initial_size, item)
        list.items << item
        0
      end

      # xmlSchemaItemListInsert
      def item_list_insert(list, item, idx)
        # Just append if the index is greater/equal than the item count.
        if idx >= list.items.size
          list.items << item
        else
          list.items.insert(idx, item)
        end
        0
      end

      # xmlSchemaItemListInsertSize (#if 0 in C)
      def item_list_insert_size(list, _initial_size, item, idx)
        item_list_insert(list, item, idx)
      end

      # xmlSchemaItemListRemove
      def item_list_remove(list, idx)
        items = list.items
        return -1 if items.nil? || idx >= items.size

        items.delete_at(idx)
        0
      end

      # Free functions: nothing to do in Ruby.
      # xmlSchemaItemListFree
      def item_list_free(_list) = nil
      # xmlSchemaBucketFree
      def bucket_free(_bucket) = nil
      # xmlSchemaBucketFreeEntry
      def bucket_free_entry(_bucket, _name) = nil
      # xmlSchemaFreeAnnot
      def free_annot(_annot) = nil
      # xmlSchemaFreeNotation
      def free_notation(_nota) = nil
      # xmlSchemaFreeAttribute
      def free_attribute(_attr) = nil
      # xmlSchemaFreeAttributeUse
      def free_attribute_use(_use) = nil
      # xmlSchemaFreeAttributeUseProhib
      def free_attribute_use_prohib(_prohib) = nil
      # xmlSchemaFreeWildcardNsSet
      def free_wildcard_ns_set(_set) = nil
      # xmlSchemaFreeWildcard
      def free_wildcard(_wildcard) = nil
      # xmlSchemaFreeAttributeGroup
      def free_attribute_group(_attr_gr) = nil
      # xmlSchemaFreeQNameRef
      def free_q_name_ref(_item) = nil
      # xmlSchemaFreeTypeLinkList
      def free_type_link_list(_link) = nil
      # xmlSchemaFreeIDCStateObjList
      def free_idc_state_obj_list(_sto) = nil
      # xmlSchemaFreeIDC
      def free_idc(_idc_def) = nil
      # xmlSchemaFreeElement
      def free_element(_elem) = nil
      # xmlSchemaFreeFacet
      def free_facet(_facet) = nil
      # xmlSchemaFreeType
      def free_type(_type) = nil
      # xmlSchemaFreeModelGroupDef
      def free_model_group_def(_item) = nil
      # xmlSchemaFreeModelGroup
      def free_model_group(_item) = nil
      # xmlSchemaComponentListFree
      def component_list_free(_list) = nil
      # xmlSchemaFree
      def free(_schema) = nil
      # xmlSchemaSubstGroupFree
      def subst_group_free(_group) = nil
      # xmlSchemaSubstGroupFreeEntry
      def subst_group_free_entry(_group, _name) = nil

      # xmlSchemaBucketCreate
      def bucket_create(pctxt, type, target_namespace)
        con = pctxt.constructor
        if con.main_schema.nil?
          internal_err(pctxt, "xmlSchemaBucketCreate", "no main schema on constructor")
          return nil
        end
        main_schema = con.main_schema
        # Create the schema bucket.
        ret = SchemaBucket.new
        ret.target_namespace = target_namespace
        ret.type = type
        ret.globals = SchemaItemList.new
        ret.locals = SchemaItemList.new
        # The following will assure that only the first bucket is marked as
        # XML_SCHEMA_SCHEMA_MAIN and it points to the *main* schema. For each following import
        # buckets an xmlSchema will be created. An xmlSchema will be created for every distinct
        # targetNamespace. We assign the targetNamespace to the schemata here.
        if !wxs_has_buckets(pctxt)
          if wxs_is_bucket_incredef(type)
            internal_err(pctxt, "xmlSchemaBucketCreate",
              "first bucket but it's an include or redefine")
            return nil
          end
          # Force the type to be XML_SCHEMA_SCHEMA_MAIN.
          ret.type = XML_SCHEMA_SCHEMA_MAIN
          # Point to the *main* schema.
          con.main_bucket = ret
          ret.schema = main_schema
          # Ensure that the main schema gets a targetNamespace.
          main_schema.target_namespace = target_namespace
        elsif type == XML_SCHEMA_SCHEMA_MAIN
          internal_err(pctxt, "xmlSchemaBucketCreate",
            "main bucket but it's not the first one")
          return nil
        elsif type == XML_SCHEMA_SCHEMA_IMPORT
          # Create a schema for imports and assign the targetNamespace.
          ret.schema = new_schema(pctxt)
          ret.schema.target_namespace = target_namespace
        end
        if wxs_is_bucket_impmain(type)
          # Imports go into the "schemasImports" slot of the main *schema*. Note that we create
          # an import entry for the main schema as well; i.e., even if there's only one
          # schema, we'll get an import.
          imports = (main_schema.schemas_imports ||= {})
          key = target_namespace.nil? ? XML_SCHEMAS_NO_NAMESPACE : target_namespace
          if imports.key?(key)
            internal_err(pctxt, "xmlSchemaBucketCreate",
              "failed to add the schema bucket to the hash")
            return nil
          end
          imports[key] = ret
        else
          # Set the @ownerImport of an include bucket.
          cur = con.bucket
          ret.owner_import = if wxs_is_bucket_impmain(cur.type)
            cur
          else
            cur.owner_import
          end
          # Includes got into the "includes" slot of the *main* schema.
          (main_schema.includes ||= SchemaItemList.new).items << ret
        end
        # Add to list of all buckets; this is used for lookup during schema construction
        # time only.
        (con.buckets ||= SchemaItemList.new).items << ret
        ret
      end

      # xmlSchemaAddItemSize(xmlSchemaItemListPtr *list, ...) -> [ret, list]
      def add_item_size(list, initial_size, item)
        list = item_list_create if list.nil?
        [item_list_add_size(list, initial_size, item), list]
      end

      # ------------------------------------------------------------------------------------
      # Utilities
      # ------------------------------------------------------------------------------------

      # xmlSchemaGetPropNode: attribute +name+ in no namespace
      def get_prop_node(node, name)
        return nil if node.nil? || name.nil?

        prop = node.properties
        while prop
          return prop if prop.ns.nil? && prop.name == name

          prop = prop.next
        end
        nil
      end

      # xmlSchemaGetPropNodeNs
      def get_prop_node_ns(node, uri, name)
        return nil if node.nil? || name.nil?

        prop = node.properties
        while prop
          return prop if prop.ns && prop.name == name && prop.ns.href == uri

          prop = prop.next
        end
        nil
      end

      # xmlSchemaGetNodeContent
      def get_node_content(_ctxt, node)
        Tree.node_get_content(node) || +""
      end

      # xmlSchemaGetNodeContentNoDict
      def get_node_content_no_dict(node)
        Tree.node_get_content(node)
      end

      # xmlSchemaGetProp
      def get_prop(_ctxt, node, name)
        Tree.get_no_ns_prop(node, name)
      end

      # WXS_FIND_GLOBAL_ITEM(slot)
      def wxs_find_global_item(schema, slot, name, ns_name)
        if ns_name == schema.target_namespace
          h = schema.public_send(slot)
          ret = h && h[name]
          return ret if ret
        end
        imports = schema.schemas_imports
        if imports && imports.size > 1
          import = imports[ns_name.nil? ? XML_SCHEMAS_NO_NAMESPACE : ns_name]
          return nil if import.nil?

          h = import.schema.public_send(slot)
          return h && h[name]
        end
        nil
      end
      private :wxs_find_global_item

      # xmlSchemaGetElem
      def get_elem(schema, name, ns_name)
        return nil if name.nil? || schema.nil?

        wxs_find_global_item(schema, :elem_decl, name, ns_name)
      end

      # xmlSchemaGetType
      def get_type(schema, name, ns_name)
        return nil if name.nil?

        # First try the built-in types.
        if ns_name && ns_name == XML_SCHEMAS_NS
          ret = Types.get_predefined_type(name, ns_name)
          return ret if ret
          # Note that we try the parsed schemas as well here since one might have parsed the
          # S4S, which contain more than the built-in types.
        end
        return nil if schema.nil?

        wxs_find_global_item(schema, :type_decl, name, ns_name)
      end

      # xmlSchemaGetAttributeDecl
      def get_attribute_decl(schema, name, ns_name)
        return nil if name.nil? || schema.nil?

        wxs_find_global_item(schema, :attr_decl, name, ns_name)
      end

      # xmlSchemaGetAttributeGroup
      def get_attribute_group(schema, name, ns_name)
        return nil if name.nil? || schema.nil?

        wxs_find_global_item(schema, :attrgrp_decl, name, ns_name)
      end

      # xmlSchemaGetGroup
      def get_group(schema, name, ns_name)
        return nil if name.nil? || schema.nil?

        wxs_find_global_item(schema, :group_decl, name, ns_name)
      end

      # xmlSchemaGetNotation
      def get_notation(schema, name, ns_name)
        return nil if name.nil? || schema.nil?

        wxs_find_global_item(schema, :nota_decl, name, ns_name)
      end

      # xmlSchemaGetIDC
      def get_idc(schema, name, ns_name)
        return nil if name.nil? || schema.nil?

        wxs_find_global_item(schema, :idc_def, name, ns_name)
      end

      # xmlSchemaGetNamedComponent
      def get_named_component(schema, item_type, name, target_ns)
        case item_type
        when XML_SCHEMA_TYPE_GROUP
          get_group(schema, name, target_ns)
        when XML_SCHEMA_TYPE_ELEMENT
          get_elem(schema, name, target_ns)
        end
      end

      # xmlSchemaIsBlank: 1 if +str+ is nil or only made of blanks (first +len+ bytes if
      # len >= 0), 0 otherwise
      def is_blank(str, len = -1)
        return 1 if str.nil?

        n = str.bytesize
        n = len if len >= 0 && len < n
        i = 0
        while i < n
          c = str.getbyte(i)
          break if c == 0
          return 0 unless c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D

          i += 1
        end
        1
      end

      # IS_BLANK_NODE(n)
      def is_blank_node(n)
        n.type == TEXT_NODE && is_blank(n.content, -1) != 0
      end

      # xmlSchemaFindRedefCompInGraph
      def find_redef_comp_in_graph(bucket, type, name, ns_name)
        return nil if bucket.nil? || name.nil?

        globals = bucket.globals
        if globals && globals.nb_items != 0
          # Search in global components.
          globals.items.each do |ret|
            next unless ret.type == type

            case type
            when XML_SCHEMA_TYPE_COMPLEX, XML_SCHEMA_TYPE_SIMPLE, XML_SCHEMA_TYPE_GROUP,
                 XML_SCHEMA_TYPE_ATTRIBUTEGROUP
              return ret if ret.name == name && ret.target_namespace == ns_name
            else
              # Should not be hit.
              return nil
            end
          end
        end
        # subschemas: process imported/included schemas.
        if bucket.relations
          rel = bucket.relations
          # TODO: Marking the bucket will not avoid multiple searches in the same schema, but
          # avoids at least circularity.
          bucket.flags |= XML_SCHEMA_BUCKET_MARKED
          loop do
            if rel.bucket && (rel.bucket.flags & XML_SCHEMA_BUCKET_MARKED) == 0
              ret = find_redef_comp_in_graph(rel.bucket, type, name, ns_name)
              return ret if ret
            end
            rel = rel.next
            break if rel.nil?
          end
          bucket.flags ^= XML_SCHEMA_BUCKET_MARKED
        end
        nil
      end

      # ------------------------------------------------------------------------------------
      # Component constructors
      # ------------------------------------------------------------------------------------

      # xmlSchemaAddNotation
      def add_notation(ctxt, schema, name, ns_name, _node)
        return nil if ctxt.nil? || schema.nil? || name.nil?

        ret = SchemaNotation.new(type: XML_SCHEMA_TYPE_NOTATION, name: name, target_namespace: ns_name)
        wxs_add_global(ctxt, ret)
        ret
      end

      # xmlSchemaAddAttribute
      def add_attribute(ctxt, schema, name, ns_name, node, top_level)
        return nil if ctxt.nil? || schema.nil?

        ret = SchemaAttribute.new(type: XML_SCHEMA_TYPE_ATTRIBUTE, node: node, name: name,
          target_namespace: ns_name)
        if top_level && top_level != 0
          wxs_add_global(ctxt, ret)
        else
          wxs_add_local(ctxt, ret)
        end
        wxs_add_pending(ctxt, ret)
        ret
      end

      # xmlSchemaAddAttributeUse
      def add_attribute_use(pctxt, node)
        return nil if pctxt.nil?

        ret = SchemaAttributeUse.new(type: XML_SCHEMA_TYPE_ATTRIBUTE_USE, node: node)
        wxs_add_local(pctxt, ret)
        ret
      end

      # xmlSchemaAddRedef
      def add_redef(pctxt, target_bucket, item, ref_name, ref_target_ns)
        ret = SchemaRedef.new(item: item, target_bucket: target_bucket, ref_name: ref_name,
          ref_target_ns: ref_target_ns)
        con = pctxt.constructor
        if con.redefs.nil?
          con.redefs = ret
        else
          con.last_redef.next = ret
        end
        con.last_redef = ret
        ret
      end

      # xmlSchemaAddAttributeGroupDefinition
      def add_attribute_group_definition(pctxt, _schema, name, ns_name, node)
        return nil if pctxt.nil? || name.nil?

        ret = SchemaAttributeGroup.new(type: XML_SCHEMA_TYPE_ATTRIBUTEGROUP, name: name,
          target_namespace: ns_name, node: node)
        # TODO: Remove the flag.
        ret.flags |= XML_SCHEMAS_ATTRGROUP_GLOBAL
        if pctxt.is_redefine != 0 && pctxt.is_redefine != false
          pctxt.redef = add_redef(pctxt, pctxt.redefined, ret, name, ns_name)
          return nil if pctxt.redef.nil?

          pctxt.redef_counter = 0
        end
        wxs_add_global(pctxt, ret)
        wxs_add_pending(pctxt, ret)
        ret
      end

      # xmlSchemaAddElement
      def add_element(ctxt, name, ns_name, node, top_level)
        return nil if ctxt.nil? || name.nil?

        ret = SchemaElement.new(type: XML_SCHEMA_TYPE_ELEMENT, name: name,
          target_namespace: ns_name, node: node)
        if top_level && top_level != 0
          wxs_add_global(ctxt, ret)
        else
          wxs_add_local(ctxt, ret)
        end
        wxs_add_pending(ctxt, ret)
        ret
      end

      # xmlSchemaAddType
      def add_type(ctxt, schema, type, name, ns_name, node, top_level)
        return nil if ctxt.nil? || schema.nil?

        ret = SchemaType.new(type: type, name: name, target_namespace: ns_name, node: node)
        if top_level && top_level != 0
          if ctxt.is_redefine != 0 && ctxt.is_redefine != false
            ctxt.redef = add_redef(ctxt, ctxt.redefined, ret, name, ns_name)
            return nil if ctxt.redef.nil?

            ctxt.redef_counter = 0
          end
          wxs_add_global(ctxt, ret)
        else
          wxs_add_local(ctxt, ret)
        end
        wxs_add_pending(ctxt, ret)
        ret
      end

      # xmlSchemaNewQNameRef
      def new_q_name_ref(pctxt, ref_type, ref_name, ref_ns)
        ret = SchemaQNameRef.new(type: XML_SCHEMA_EXTRA_QNAMEREF, node: nil, name: ref_name,
          target_namespace: ref_ns, item: nil, item_type: ref_type)
        # Store the reference item in the schema.
        wxs_add_local(pctxt, ret)
        ret
      end

      # xmlSchemaAddAttributeUseProhib
      def add_attribute_use_prohib(pctxt)
        ret = SchemaAttributeUseProhib.new(type: XML_SCHEMA_EXTRA_ATTR_USE_PROHIB)
        wxs_add_local(pctxt, ret)
        ret
      end

      # xmlSchemaAddModelGroup
      def add_model_group(ctxt, schema, type, node)
        return nil if ctxt.nil? || schema.nil?

        ret = SchemaModelGroup.new(type: type, node: node)
        wxs_add_local(ctxt, ret)
        if type == XML_SCHEMA_TYPE_SEQUENCE || type == XML_SCHEMA_TYPE_CHOICE
          wxs_add_pending(ctxt, ret)
        end
        ret
      end

      # xmlSchemaAddParticle
      def add_particle(ctxt, node, min, max)
        return nil if ctxt.nil?

        ret = SchemaParticle.new(type: XML_SCHEMA_TYPE_PARTICLE, annot: nil, node: node,
          min_occurs: min, max_occurs: max, next: nil, children: nil)
        wxs_add_local(ctxt, ret)
        # Note that addition to pending components will be done locally to the specific
        # parsing function, since the most particles need not to be fixed up.
        ret
      end

      # xmlSchemaAddModelGroupDefinition
      def add_model_group_definition(ctxt, schema, name, ns_name, node)
        return nil if ctxt.nil? || schema.nil? || name.nil?

        ret = SchemaModelGroupDef.new(name: name, type: XML_SCHEMA_TYPE_GROUP, node: node,
          target_namespace: ns_name)
        if ctxt.is_redefine != 0 && ctxt.is_redefine != false
          ctxt.redef = add_redef(ctxt, ctxt.redefined, ret, name, ns_name)
          return nil if ctxt.redef.nil?

          ctxt.redef_counter = 0
        end
        wxs_add_global(ctxt, ret)
        wxs_add_pending(ctxt, ret)
        ret
      end

      # xmlSchemaNewWildcardNsConstraint
      def new_wildcard_ns_constraint(_ctxt)
        SchemaWildcardNs.new(value: nil, next: nil)
      end

      # xmlSchemaAddIDC
      def add_idc(ctxt, schema, name, ns_name, category, node)
        return nil if ctxt.nil? || schema.nil? || name.nil?

        # The target namespace of the parent element declaration.
        ret = SchemaIDC.new(target_namespace: ns_name, name: name, type: category, node: node)
        wxs_add_global(ctxt, ret)
        # Only keyrefs need to be fixup up.
        wxs_add_pending(ctxt, ret) if category == XML_SCHEMA_TYPE_IDC_KEYREF
        ret
      end

      # xmlSchemaAddWildcard
      def add_wildcard(ctxt, schema, type, node)
        return nil if ctxt.nil? || schema.nil?

        ret = SchemaWildcard.new(type: type, node: node)
        wxs_add_local(ctxt, ret)
        ret
      end

      # ------------------------------------------------------------------------------------
      # Substitution groups. WXS_SUBST_GROUPS(pctxt) (constructor.subst_groups) is a Ruby Hash
      # keyed by [head.name, head.target_namespace] (xmlHashAddEntry2 name/name2).
      # ------------------------------------------------------------------------------------

      # xmlSchemaSubstGroupAdd
      def subst_group_add(pctxt, head)
        # Init subst group hash.
        groups = (pctxt.constructor.subst_groups ||= {})
        # Create a new substitution group.
        ret = SchemaSubstGroup.new(head: head, members: SchemaItemList.new)
        # Add subst group to hash.
        key = [head.name, head.target_namespace]
        if groups.key?(key)
          internal_err(pctxt, "xmlSchemaSubstGroupAdd",
            "failed to add a new substitution container")
          return nil
        end
        groups[key] = ret
        ret
      end

      # xmlSchemaSubstGroupGet
      def subst_group_get(pctxt, head)
        groups = pctxt.constructor.subst_groups
        return nil if groups.nil?

        groups[[head.name, head.target_namespace]]
      end

      # xmlSchemaAddElementSubstitutionMember
      def add_element_substitution_member(pctxt, head, member)
        return -1 if pctxt.nil? || head.nil? || member.nil?

        subst_group = subst_group_get(pctxt, head)
        subst_group = subst_group_add(pctxt, head) if subst_group.nil?
        return -1 if subst_group.nil?

        item_list_add(subst_group.members, member)
      end
    end
  end
end
