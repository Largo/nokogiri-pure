# frozen_string_literal: true

require_relative "structs"
require_relative "common"

# The WXS_* / IS_SCHEMA helper macros of xmlschemas.c as Ruby methods (all in module Schemas).
# Casting macros (WXS_TYPE_CAST, ...) vanish in Ruby; field-access macros are written inline:
#   WXS_ELEM_TYPEDEF(e) -> e.subtypes            WXS_SUBST_HEAD(e) -> e.ref_decl
#   WXS_ATTR_TYPEDEF(a) -> a.subtypes            WXS_ATTRUSE_DECL(au) -> au.attr_decl
#   WXS_ATTRUSE_TYPEDEF(au) -> au.attr_decl.subtypes
#   WXS_ATTRUSE_DECL_NAME(au) -> au.attr_decl.name, WXS_ATTRUSE_DECL_TNS(au) -> au.attr_decl.target_namespace
#   WXS_PARTICLE_TERM(p) -> p.children           WXS_MODELGROUPDEF_MODEL(mgd) -> mgd.children
#   WXS_TYPE_CONTENTTYPE(t) / WXS_TYPE_PARTICLE(t) -> t.subtypes
#   WXS_TYPE_PARTICLE_TERM(t) -> t.subtypes.children   WXS_LIST_ITEMTYPE(t) -> t.subtypes
#   WXS_CONSTRUCTOR(ctx) -> ctx.constructor      WXS_BUCKET(ctx) -> ctx.constructor.bucket
#   WXS_SUBST_GROUPS(ctx) -> ctx.constructor.subst_groups   WXS_SCHEMA(ctx) -> ctx.schema
#   WXS_ITEM_NODE(i) -> get_component_node(i)    WXS_ITEM_TYPE_NAME(i) -> get_component_type_str(i)
module Nokogiri
  module Pure
    module Schemas
      extend self

      # IS_SCHEMA(node, type)
      def is_schema(node, name)
        !node.nil? && !node.ns.nil? && node.name == name && node.ns.href == XML_SCHEMAS_NS
      end

      def wxs_is_model_group(i)
        t = i.type
        t == XML_SCHEMA_TYPE_SEQUENCE || t == XML_SCHEMA_TYPE_CHOICE || t == XML_SCHEMA_TYPE_ALL
      end

      def wxs_is_bucket_incredef(t) = t == XML_SCHEMA_SCHEMA_INCLUDE || t == XML_SCHEMA_SCHEMA_REDEFINE
      def wxs_is_bucket_impmain(t) = t == XML_SCHEMA_SCHEMA_MAIN || t == XML_SCHEMA_SCHEMA_IMPORT

      def wxs_is_anytype(i)
        i.type == XML_SCHEMA_TYPE_BASIC && i.built_in_type == XML_SCHEMAS_ANYTYPE
      end

      def wxs_is_complex(i)
        i.type == XML_SCHEMA_TYPE_COMPLEX || i.built_in_type == XML_SCHEMAS_ANYTYPE
      end

      def wxs_is_simple(i)
        i.type == XML_SCHEMA_TYPE_SIMPLE ||
          (i.type == XML_SCHEMA_TYPE_BASIC && i.built_in_type != XML_SCHEMAS_ANYTYPE)
      end

      def wxs_is_any_simple_type(i)
        i.type == XML_SCHEMA_TYPE_BASIC && i.built_in_type == XML_SCHEMAS_ANYSIMPLETYPE
      end

      def wxs_is_restriction(t) = (t.flags & XML_SCHEMAS_TYPE_DERIVATION_METHOD_RESTRICTION) != 0
      def wxs_is_extension(t) = (t.flags & XML_SCHEMAS_TYPE_DERIVATION_METHOD_EXTENSION) != 0

      def wxs_is_type_not_fixed(i)
        i.type != XML_SCHEMA_TYPE_BASIC && (i.flags & XML_SCHEMAS_TYPE_INTERNAL_RESOLVED) == 0
      end

      def wxs_is_type_not_fixed_1(i)
        i.type != XML_SCHEMA_TYPE_BASIC && (i.flags & XML_SCHEMAS_TYPE_FIXUP_1) == 0
      end

      def wxs_type_is_global(t) = (t.flags & XML_SCHEMAS_TYPE_GLOBAL) != 0
      def wxs_type_is_local(t) = (t.flags & XML_SCHEMAS_TYPE_GLOBAL) == 0

      def wxs_has_complex_content(i)
        ct = i.content_type
        ct == XML_SCHEMA_CONTENT_MIXED || ct == XML_SCHEMA_CONTENT_EMPTY || ct == XML_SCHEMA_CONTENT_ELEMENTS
      end

      def wxs_has_simple_content(i)
        ct = i.content_type
        ct == XML_SCHEMA_CONTENT_SIMPLE || ct == XML_SCHEMA_CONTENT_BASIC
      end

      def wxs_has_mixed_content(i) = i.content_type == XML_SCHEMA_CONTENT_MIXED

      # WXS_EMPTIABLE(t)
      def wxs_emptiable(t) = is_particle_emptiable(t.subtypes)

      def wxs_is_atomic(t) = (t.flags & XML_SCHEMAS_TYPE_VARIETY_ATOMIC) != 0
      def wxs_is_list(t) = (t.flags & XML_SCHEMAS_TYPE_VARIETY_LIST) != 0
      def wxs_is_union(t) = (t.flags & XML_SCHEMAS_TYPE_VARIETY_UNION) != 0

      def wxs_attr_group_has_refs(ag) = (ag.flags & XML_SCHEMAS_ATTRGROUP_HAS_REFS) != 0
      def wxs_attr_group_expanded(ag) = (ag.flags & XML_SCHEMAS_ATTRGROUP_WILDCARD_BUILDED) != 0

      def wxs_has_buckets(ctx)
        !ctx.constructor.buckets.nil? && ctx.constructor.buckets.nb_items > 0
      end

      # WXS_ADD_LOCAL / WXS_ADD_GLOBAL / WXS_ADD_PENDING
      def wxs_add_local(ctx, item)
        b = ctx.constructor.bucket
        (b.locals ||= SchemaItemList.new).items << item
        item
      end

      def wxs_add_global(ctx, item)
        b = ctx.constructor.bucket
        (b.globals ||= SchemaItemList.new).items << item
        item
      end

      def wxs_add_pending(ctx, item)
        (ctx.constructor.pending ||= SchemaItemList.new).items << item
        0
      end

      # WXS_ILIST_IS_EMPTY
      def wxs_ilist_is_empty(l) = l.nil? || l.nb_items == 0

      # INODE_NILLED
      def inode_nilled(item) = (item.flags & XML_SCHEMA_ELEM_INFO_NILLED) != 0

      # CAN_PARSE_SCHEMA(b)
      def can_parse_schema(b) = !b.doc.nil? && b.parsed == 0
    end
  end
end
