# frozen_string_literal: true

require_relative "structs"
require_relative "macros"
require_relative "common"
require_relative "parse"

# Port of xmlschemas.c (libxml2 2.13.9) lines ~9500-11147 and 12337-12502: schema document
# handling (cleanup, <schema> element, top level), schema buckets and relations, the
# import/include/redefine machinery (xmlSchemaAddSchemaDoc) and parser-context creation.
#
# Ruby signatures that differ from the plain C mapping:
#   add_schema_doc(pctxt, type, schema_location, schema_doc, schema_buffer,
#                  schema_buffer_len, invoking_node, source_target_namespace,
#                  import_namespace)                                   -> [ret, bucket]
#   parse_include_or_redefine_attrs(pctxt, schema, node, type)         -> [ret, schema_location]
module Nokogiri
  module Pure
    module Schemas
      extend self

      # xmlSchemaCleanupDoc: removes unwanted nodes in a schemas document tree
      def cleanup_doc(ctxt, root)
        return if ctxt.nil? || root.nil?

        # Remove all the blank text nodes
        delete = nil
        cur = root
        while cur
          if delete
            Tree.unlink_node(delete)
            delete = nil
          end
          skip_children = false
          if cur.type == TEXT_NODE
            # IS_BLANK_NODE(cur)
            content = cur.content
            if (content.nil? || !content.match?(/[^ \t\n\r]/)) && Tree.node_get_space_preserve(cur) != 1
              delete = cur
            end
          elsif cur.type != ELEMENT_NODE && cur.type != CDATA_SECTION_NODE
            delete = cur
            skip_children = true
          end
          # Skip to next node
          if !skip_children && cur.children
            t = cur.children.type
            if t != ENTITY_DECL && t != ENTITY_REF_NODE && t != ENTITY_NODE
              cur = cur.children
              next
            end
          end
          # skip_children:
          if cur.next
            cur = cur.next
            next
          end
          loop do
            cur = cur.parent
            break if cur.nil?

            if cur.equal?(root)
              cur = nil
              break
            end
            if cur.next
              cur = cur.next
              break
            end
          end
        end
        Tree.unlink_node(delete) if delete
      end

      CLEAR_SCHEMA_DEFAULT_FLAGS = [
        XML_SCHEMAS_QUALIF_ELEM, XML_SCHEMAS_QUALIF_ATTR,
        XML_SCHEMAS_FINAL_DEFAULT_EXTENSION, XML_SCHEMAS_FINAL_DEFAULT_RESTRICTION,
        XML_SCHEMAS_FINAL_DEFAULT_LIST, XML_SCHEMAS_FINAL_DEFAULT_UNION,
        XML_SCHEMAS_BLOCK_DEFAULT_EXTENSION, XML_SCHEMAS_BLOCK_DEFAULT_RESTRICTION,
        XML_SCHEMAS_BLOCK_DEFAULT_SUBSTITUTION,
      ].freeze

      # xmlSchemaClearSchemaDefaults
      def clear_schema_defaults(schema)
        CLEAR_SCHEMA_DEFAULT_FLAGS.each do |f|
          schema.flags ^= f if (schema.flags & f) != 0
        end
      end

      # xmlSchemaParseSchemaElement
      def parse_schema_element(ctxt, schema, node)
        old_errs = ctxt.nberrors
        # Those flags should be moved to the parser context flags, since they are not visible
        # at the component level. I.e. they are used if processing schema *documents* only.
        res = p_val_attr_id(ctxt, node, "id")
        return -1 if res == -1 # HFAILURE

        catch(:exit) do
          # Since the version is of type xs:token, we won't bother to check it.
          attr = get_prop_node(node, "targetNamespace")
          if attr
            res, = p_val_attr_node(ctxt, nil, attr, Types.get_built_in_type(XML_SCHEMAS_ANYURI))
            return -1 if res == -1

            if res != 0
              ctxt.stop = ErrCode::SCHEMAP_S4S_ATTR_INVALID_VALUE
              throw :exit
            end
          end
          attr = get_prop_node(node, "elementFormDefault")
          if attr
            val = get_node_content(ctxt, attr)
            res, schema.flags = p_val_attr_form_default(val, schema.flags, XML_SCHEMAS_QUALIF_ELEM)
            return -1 if res == -1

            if res != 0
              p_simple_type_err(ctxt, ErrCode::SCHEMAP_ELEMFORMDEFAULT_VALUE, nil, attr, nil,
                "(qualified | unqualified)", val, nil, nil, nil)
            end
          end
          attr = get_prop_node(node, "attributeFormDefault")
          if attr
            val = get_node_content(ctxt, attr)
            res, schema.flags = p_val_attr_form_default(val, schema.flags, XML_SCHEMAS_QUALIF_ATTR)
            return -1 if res == -1

            if res != 0
              p_simple_type_err(ctxt, ErrCode::SCHEMAP_ATTRFORMDEFAULT_VALUE, nil, attr, nil,
                "(qualified | unqualified)", val, nil, nil, nil)
            end
          end
          attr = get_prop_node(node, "finalDefault")
          if attr
            val = get_node_content(ctxt, attr)
            res, schema.flags = p_val_attr_block_final(val, schema.flags, -1,
              XML_SCHEMAS_FINAL_DEFAULT_EXTENSION, XML_SCHEMAS_FINAL_DEFAULT_RESTRICTION, -1,
              XML_SCHEMAS_FINAL_DEFAULT_LIST, XML_SCHEMAS_FINAL_DEFAULT_UNION)
            return -1 if res == -1

            if res != 0
              p_simple_type_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_INVALID_VALUE, nil, attr, nil,
                "(#all | List of (extension | restriction | list | union))", val, nil, nil, nil)
            end
          end
          attr = get_prop_node(node, "blockDefault")
          if attr
            val = get_node_content(ctxt, attr)
            res, schema.flags = p_val_attr_block_final(val, schema.flags, -1,
              XML_SCHEMAS_BLOCK_DEFAULT_EXTENSION, XML_SCHEMAS_BLOCK_DEFAULT_RESTRICTION,
              XML_SCHEMAS_BLOCK_DEFAULT_SUBSTITUTION, -1, -1)
            return -1 if res == -1

            if res != 0
              p_simple_type_err(ctxt, ErrCode::SCHEMAP_S4S_ATTR_INVALID_VALUE, nil, attr, nil,
                "(#all | List of (extension | restriction | substitution))", val, nil, nil, nil)
            end
          end
        end
        # exit:
        res = ctxt.err if old_errs != ctxt.nberrors
        res
      end

      TOP_LEVEL_CONTENT_MODEL =
        "((include | import | redefine | annotation)*, " \
        "(((simpleType | complexType | group | attributeGroup) " \
        "| element | attribute | notation), annotation*)*)"

      # xmlSchemaParseSchemaTopLevel
      def parse_schema_top_level(ctxt, schema, nodes)
        return -1 if ctxt.nil? || schema.nil? || nodes.nil?

        res = 0
        old_errs = ctxt.nberrors
        child = nodes
        catch(:exit) do
          while is_schema(child, "include") || is_schema(child, "import") ||
              is_schema(child, "redefine") || is_schema(child, "annotation")
            if is_schema(child, "annotation")
              annot = parse_annotation(ctxt, child, 1)
              schema.annot = annot if schema.annot.nil?
            elsif is_schema(child, "import")
              tmp_old_errs = ctxt.nberrors
              res = parse_import(ctxt, schema, child)
              return -1 if res == -1 # HFAILURE
              throw :exit if ctxt.stop != 0 # HSTOP
              throw :exit if tmp_old_errs != ctxt.nberrors
            elsif is_schema(child, "include")
              tmp_old_errs = ctxt.nberrors
              res = parse_include(ctxt, schema, child)
              return -1 if res == -1
              throw :exit if ctxt.stop != 0
              throw :exit if tmp_old_errs != ctxt.nberrors
            elsif is_schema(child, "redefine")
              tmp_old_errs = ctxt.nberrors
              res = parse_redefine(ctxt, schema, child)
              return -1 if res == -1
              throw :exit if ctxt.stop != 0
              throw :exit if tmp_old_errs != ctxt.nberrors
            end
            child = child.next
          end
          # URGENT TODO: Change the functions to return int results. We need especially to
          # catch internal errors.
          while child
            if is_schema(child, "complexType")
              parse_complex_type(ctxt, schema, child, 1)
              child = child.next
            elsif is_schema(child, "simpleType")
              parse_simple_type(ctxt, schema, child, 1)
              child = child.next
            elsif is_schema(child, "element")
              parse_element(ctxt, schema, child, 1)
              child = child.next
            elsif is_schema(child, "attribute")
              parse_global_attribute(ctxt, schema, child)
              child = child.next
            elsif is_schema(child, "attributeGroup")
              parse_attribute_group_definition(ctxt, schema, child)
              child = child.next
            elsif is_schema(child, "group")
              parse_model_group_definition(ctxt, schema, child)
              child = child.next
            elsif is_schema(child, "notation")
              parse_notation(ctxt, schema, child)
              child = child.next
            else
              p_content_err(ctxt, ErrCode::SCHEMAP_S4S_ELEM_NOT_ALLOWED, nil, child.parent, child,
                nil, TOP_LEVEL_CONTENT_MODEL)
              child = child.next
            end
            while is_schema(child, "annotation")
              # TODO: We should add all annotations.
              annot = parse_annotation(ctxt, child, 1)
              schema.annot = annot if schema.annot.nil?
              child = child.next
            end
          end
        end
        # exit:
        ctxt.ctxt_type = nil
        res = ctxt.err if old_errs != ctxt.nberrors
        res
      end

      # xmlSchemaSchemaRelationCreate
      def schema_relation_create
        SchemaSchemaRelation.new
      end

      # xmlSchemaRedefListFree (no-op in Ruby)
      def redef_list_free(_redef) = nil

      # xmlSchemaConstructionCtxtFree (no-op in Ruby)
      def construction_ctxt_free(_con) = nil

      # xmlSchemaConstructionCtxtCreate
      def construction_ctxt_create(dict)
        SchemaConstructionCtxt.new(buckets: SchemaItemList.new, pending: SchemaItemList.new,
          dict: dict)
      end

      # xmlSchemaParserCtxtCreate
      def parser_ctxt_create
        SchemaParserCtxt.new(attr_prohibs: SchemaItemList.new)
      end

      # xmlSchemaNewParserCtxtUseDict
      def new_parser_ctxt_use_dict(url, dict)
        ret = parser_ctxt_create
        ret.dict = dict
        ret.url = url unless url.nil?
        ret
      end

      # xmlSchemaCreatePCtxtOnVCtxt
      def create_p_ctxt_on_v_ctxt(vctxt)
        if vctxt.pctxt.nil?
          vctxt.pctxt = if vctxt.schema
            new_parser_ctxt_use_dict("*", vctxt.schema.dict)
          else
            new_parser_ctxt("*")
          end
          if vctxt.pctxt.nil?
            internal_err(vctxt, "xmlSchemaCreatePCtxtOnVCtxt", "failed to create a temp. parser context")
            return -1
          end
          # TODO: Pass user data.
          # xmlSchemaSetParserErrors + xmlSchemaSetParserStructuredErrors (the new context
          # has no vctxt, so plain assignment is equivalent)
          vctxt.pctxt.error = vctxt.error
          vctxt.pctxt.warning = vctxt.warning
          vctxt.pctxt.serror = vctxt.serror
          vctxt.pctxt.err_ctxt = vctxt.err_ctxt
        end
        0
      end

      # xmlSchemaGetSchemaBucket: a bucket if it was already parsed from +schema_location+
      def get_schema_bucket(pctxt, schema_location)
        pctxt.constructor.buckets.items.each do |cur|
          # Pointer comparison (of dict strings)!
          return cur if cur.schema_location == schema_location
        end
        nil
      end

      # xmlSchemaGetChameleonSchemaBucket
      def get_chameleon_schema_bucket(pctxt, schema_location, target_namespace)
        pctxt.constructor.buckets.items.each do |cur|
          if cur.orig_target_namespace.nil? && cur.schema_location == schema_location &&
              cur.target_namespace == target_namespace
            return cur
          end
        end
        nil
      end

      # xmlSchemaGetSchemaBucketByTNS
      def get_schema_bucket_by_tns(pctxt, target_namespace, imported)
        pctxt.constructor.buckets.items.each do |cur|
          # IS_BAD_SCHEMA_DOC(b)
          bad = cur.doc.nil? && !cur.schema_location.nil?
          if !bad && cur.orig_target_namespace == target_namespace &&
              ((imported != 0 && cur.imported != 0) || (imported == 0 && cur.imported == 0))
            return cur
          end
        end
        nil
      end

      # xmlSchemaParseNewDocWithContext
      def parse_new_doc_with_context(pctxt, schema, bucket)
        oldbucket = pctxt.constructor.bucket
        # Save old values; reset the *main* schema.
        old_flags = schema.flags
        old_doc = schema.doc
        clear_schema_defaults(schema) if schema.flags != 0
        schema.doc = bucket.doc
        pctxt.schema = schema
        # Keep the current target namespace on the parser *not* on the main schema.
        pctxt.target_namespace = bucket.target_namespace
        pctxt.constructor.bucket = bucket

        if bucket.target_namespace && bucket.target_namespace == XML_SCHEMAS_NS
          # We are parsing the schema for schemas!
          pctxt.is_s4s = 1
        end
        # Mark it as parsed, even if parsing fails.
        bucket.parsed += 1
        # Compile the schema doc.
        node = Tree.doc_get_root_element(bucket.doc)
        ret = parse_schema_element(pctxt, schema, node)
        # An empty schema; just get out.
        if ret == 0 && node.children
          old_errs = pctxt.nberrors
          ret = parse_schema_top_level(pctxt, schema, node.children)
          # TODO: Not nice, but I'm not 100% sure we will get always an error as a result of
          # the above functions; so better rely on pctxt->err as well.
          ret = pctxt.err if ret == 0 && old_errs != pctxt.nberrors
        end
        # exit:
        pctxt.constructor.bucket = oldbucket
        # Restore schema values.
        schema.doc = old_doc
        schema.flags = old_flags
        ret
      end

      # xmlSchemaParseNewDoc
      def parse_new_doc(pctxt, schema, bucket)
        return 0 if bucket.nil?

        if bucket.parsed != 0
          internal_err(pctxt, "xmlSchemaParseNewDoc", "reparsing a schema doc")
          return -1
        end
        if bucket.doc.nil?
          internal_err(pctxt, "xmlSchemaParseNewDoc", "parsing a schema doc, but there's no doc")
          return -1
        end
        if pctxt.constructor.nil?
          internal_err(pctxt, "xmlSchemaParseNewDoc", "no constructor")
          return -1
        end
        # Create and init the temporary parser context.
        newpctxt = new_parser_ctxt_use_dict(bucket.schema_location, pctxt.dict)
        return -1 if newpctxt.nil?

        newpctxt.constructor = pctxt.constructor
        # TODO: Can we avoid that the parser knows about the main schema? It would be better
        # if he knows about the current schema bucket only.
        newpctxt.schema = schema
        # xmlSchemaSetParserErrors + xmlSchemaSetParserStructuredErrors
        newpctxt.error = pctxt.error
        newpctxt.warning = pctxt.warning
        newpctxt.serror = pctxt.serror
        newpctxt.err_ctxt = pctxt.err_ctxt
        newpctxt.counter = pctxt.counter

        res = parse_new_doc_with_context(newpctxt, schema, bucket)

        # Channel back errors and cleanup the temporary parser context.
        pctxt.err = res if res != 0
        pctxt.nberrors += newpctxt.nberrors
        pctxt.counter = newpctxt.counter
        newpctxt.constructor = nil
        # Free the parser context.
        free_parser_ctxt(newpctxt)
        res
      end

      # xmlSchemaSchemaRelationAddChild
      def schema_relation_add_child(bucket, rel)
        cur = bucket.relations
        if cur.nil?
          bucket.relations = rel
          return
        end
        cur = cur.next while cur.next
        cur.next = rel
      end

      # xmlSchemaBuildAbsoluteURI: build an absolute location URI.
      def build_absolute_uri(_dict, location, ctxt_node)
        return nil if location.nil?
        return location if ctxt_node.nil?

        base = Tree.node_get_base(ctxt_node.doc, ctxt_node)
        if base.nil?
          URI_.build_uri(location, ctxt_node.doc&.url)
        else
          URI_.build_uri(location, base)
        end
      end

      # xmlSchemaAddSchemaDoc: parse an included (and to-be-redefined) XML schema document.
      # Returns [ret, bucket]: ret is 0 on success, a positive error code on errors and -1 in
      # case of an internal or API error; bucket is only set on success.
      def add_schema_doc(pctxt, type, schema_location, schema_doc, schema_buffer,
                         _schema_buffer_len, invoking_node, source_target_namespace,
                         import_namespace)
        target_namespace = nil
        relation = nil
        doc = nil
        located = 0
        preserve_doc = 0
        bkt = nil

        err = case type
        when XML_SCHEMA_SCHEMA_IMPORT, XML_SCHEMA_SCHEMA_MAIN then ErrCode::SCHEMAP_SRC_IMPORT
        when XML_SCHEMA_SCHEMA_INCLUDE then ErrCode::SCHEMAP_SRC_INCLUDE
        when XML_SCHEMA_SCHEMA_REDEFINE then ErrCode::SCHEMAP_SRC_REDEFINE
        else 0
        end

        outcome = catch(:goto) do
          # Special handling for the main schema: skip the location and relation logic and
          # just parse the doc. We need just a bucket to be returned in this case.
          if type != XML_SCHEMA_SCHEMA_MAIN && wxs_has_buckets(pctxt)
            # Note that we expect the location to be an absolute URI.
            if schema_location
              bkt = get_schema_bucket(pctxt, schema_location)
              if bkt && pctxt.constructor.bucket.equal?(bkt)
                # Report self-imports/inclusions/redefinitions.
                custom_err(pctxt, err, invoking_node, nil,
                  "The schema must not import/include/redefine itself", nil, nil)
                throw :goto, :exit
              end
            end
            # Create a relation for the graph of schemas.
            relation = schema_relation_create
            schema_relation_add_child(pctxt.constructor.bucket, relation)
            relation.type = type

            # Save the namespace import information.
            if wxs_is_bucket_impmain(type)
              relation.import_namespace = import_namespace
              # No location; this is just an import of the namespace. Note that we don't
              # assign a bucket to the relation in this case.
              throw :goto, :exit if schema_location.nil?

              target_namespace = import_namespace
            end

            # Did we already fetch the doc?
            if bkt
              if wxs_is_bucket_impmain(type) && bkt.imported == 0
                # We included/redefined and then try to import a schema, but the new location
                # provided for import was different.
                schema_location = "in_memory_buffer" if schema_location.nil?
                if schema_location != bkt.schema_location
                  custom_err(pctxt, err, invoking_node, nil,
                    "The schema document '%s' cannot be imported, since " \
                    "it was already included or redefined", schema_location, nil)
                  throw :goto, :exit
                end
              elsif !wxs_is_bucket_impmain(type) && bkt.imported != 0
                # We imported and then try to include/redefine a schema, but the new location
                # provided for the include/redefine was different.
                schema_location = "in_memory_buffer" if schema_location.nil?
                if schema_location != bkt.schema_location
                  custom_err(pctxt, err, invoking_node, nil,
                    "The schema document '%s' cannot be included or " \
                    "redefined, since it was already imported", schema_location, nil)
                  throw :goto, :exit
                end
              end
            end

            if wxs_is_bucket_impmain(type)
              # We will use the first <import> that comes with a location. Further <import>s
              # *with* a location, will result in an error.
              if bkt
                relation.bucket = bkt
                throw :goto, :exit
              end
              bkt = get_schema_bucket_by_tns(pctxt, import_namespace, 1)

              if bkt
                relation.bucket = bkt
                if bkt.schema_location.nil?
                  # First given location of the schema; load the doc.
                  bkt.schema_location = schema_location
                else
                  if schema_location != bkt.schema_location
                    # Additional location given; just skip it.
                    # URGENT TODO: We should report a warning here.
                    schema_location = "in_memory_buffer" if schema_location.nil?
                    custom_warning(pctxt, ErrCode::SCHEMAP_WARN_SKIP_SCHEMA, invoking_node, nil,
                      "Skipping import of schema located at '%s' for the " \
                      "namespace '%s', since this namespace was already " \
                      "imported with the schema located at '%s'",
                      schema_location, import_namespace, bkt.schema_location)
                  end
                  throw :goto, :exit
                end
              end
              # No bucket + first location: load the doc and create a bucket.
            else
              # <include> and <redefine>
              if bkt
                if bkt.orig_target_namespace.nil? &&
                    bkt.target_namespace != source_target_namespace
                  # Chameleon include/redefine: skip loading only if it was already build for
                  # the targetNamespace of the including schema.
                  chamel = get_chameleon_schema_bucket(pctxt, schema_location, source_target_namespace)
                  if chamel
                    # A fitting chameleon was already parsed; NOP.
                    relation.bucket = chamel
                    throw :goto, :exit
                  end
                  # We need to parse the chameleon again for a different targetNamespace.
                  bkt = nil
                else
                  relation.bucket = bkt
                  throw :goto, :exit
                end
              end
            end
            if bkt && bkt.doc
              internal_err(pctxt, "xmlSchemaAddSchemaDoc",
                "trying to load a schema doc, but a doc is already " \
                "assigned to the schema bucket")
              throw :goto, :exit_failure
            end
          end

          # doc_load: Load the document.
          if schema_doc
            doc = schema_doc
            # Don' free this one, since it was provided by the caller.
            preserve_doc = 1
            # TODO: Does the context or the doc hold the location?
            schema_location = schema_doc.url.nil? ? "in_memory_buffer" : schema_doc.url
          elsif schema_location || schema_buffer
            if schema_location
              # Parse from file.
              doc, lerr = read_schema_doc(pctxt, schema_location, nil)
            else
              # Parse from memory buffer.
              doc, lerr = read_schema_doc(pctxt, nil, schema_buffer)
              schema_location = "in_memory_buffer"
              doc.url = +schema_location if doc
            end
            # For <import>: 2.1 The referent is (a fragment of) a resource which is an XML
            # document ... TODO: (2.1) fragments of XML documents are not supported.
            # TODO: (2.2) is not supported.
            if doc.nil?
              # Check if this a parser error, or if the document could just not be located.
              if lerr.nil? || lerr.domain != Domain::IO
                # We assume a parser error here.
                located = 1
                # TODO: Error code ??
                res = ErrCode::SCHEMAP_SRC_IMPORT_2_1
                custom_err(pctxt, res, invoking_node, nil,
                  "Failed to parse the XML resource '%s'", schema_location, nil)
              end
            end
            throw :goto, :exit_error if doc.nil? && located != 0
          else
            p_err(pctxt, nil, ErrCode::SCHEMAP_NOTHING_TO_PARSE,
              "No information for parsing was provided with the " \
              "given schema parser context.\n", nil, nil)
            throw :goto, :exit_failure
          end
          # Preprocess the document.
          if doc
            located = 1
            doc_elem = Tree.doc_get_root_element(doc)
            if doc_elem.nil?
              custom_err(pctxt, ErrCode::SCHEMAP_NOROOT, invoking_node, nil,
                "The document '%s' has no document element", schema_location, nil)
              throw :goto, :exit_error
            end
            # Remove all the blank text nodes.
            cleanup_doc(pctxt, doc_elem)
            # Check the schema's top level element.
            unless is_schema(doc_elem, "schema")
              custom_err(pctxt, ErrCode::SCHEMAP_NOT_SCHEMA, invoking_node, nil,
                "The XML document '%s' is not a schema document", schema_location, nil)
              throw :goto, :exit_error
            end
            # Note that we don't apply a type check for the targetNamespace value here.
            target_namespace = get_prop(pctxt, doc_elem, "targetNamespace")
          end

          # after_doc_loading:
          if bkt.nil? && located != 0
            # Only create a bucket if the schema was located.
            bkt = bucket_create(pctxt, type, target_namespace)
            throw :goto, :exit_failure if bkt.nil?
          end
          if bkt
            bkt.schema_location = schema_location
            bkt.located = located
            if doc
              bkt.doc = doc
              bkt.target_namespace = target_namespace
              bkt.orig_target_namespace = target_namespace
              bkt.preserve_doc = 1 if preserve_doc != 0
            end
            bkt.imported += 1 if wxs_is_bucket_impmain(type)
            # Add it to the graph of schemas.
            relation.bucket = bkt if relation
          end
          :exit
        end

        case outcome
        when :exit
          # Return the bucket explicitly; this is needed for the main schema.
          [0, bkt]
        when :exit_error
          bkt.doc = nil if doc && preserve_doc == 0 && bkt
          [pctxt.err, nil]
        else # :exit_failure
          bkt.doc = nil if doc && preserve_doc == 0 && bkt
          [-1, nil]
        end
      end

      IMPORT_ALLOWED_ATTRS = %w[id namespace schemaLocation].freeze

      # xmlSchemaParseImport
      def parse_import(pctxt, schema, node)
        return -1 if pctxt.nil? || schema.nil? || node.nil?

        # Check for illegal attributes.
        p_check_illegal_attrs(pctxt, node, IMPORT_ALLOWED_ATTRS)
        # Extract and validate attributes.
        r, namespace_name = p_val_attr(pctxt, nil, node, "namespace",
          Types.get_built_in_type(XML_SCHEMAS_ANYURI))
        if r != 0
          p_simple_type_err(pctxt, ErrCode::SCHEMAP_S4S_ATTR_INVALID_VALUE, nil, node,
            Types.get_built_in_type(XML_SCHEMAS_ANYURI), nil, namespace_name, nil, nil, nil)
          return pctxt.err
        end

        r, schema_location = p_val_attr(pctxt, nil, node, "schemaLocation",
          Types.get_built_in_type(XML_SCHEMAS_ANYURI))
        if r != 0
          p_simple_type_err(pctxt, ErrCode::SCHEMAP_S4S_ATTR_INVALID_VALUE, nil, node,
            Types.get_built_in_type(XML_SCHEMAS_ANYURI), nil, schema_location, nil, nil, nil)
          return pctxt.err
        end
        # And now for the children...
        child = node.children
        if is_schema(child, "annotation")
          # the annotation here is simply discarded ...
          child = child.next
        end
        if child
          p_content_err(pctxt, ErrCode::SCHEMAP_S4S_ELEM_NOT_ALLOWED, nil, node, child, nil,
            "(annotation?)")
        end
        # Apply additional constraints.
        # Note that it is important to use the original @targetNamespace (or none at all),
        # to rule out imports of schemas _with_ a @targetNamespace if the importing schema is
        # a chameleon schema (with no @targetNamespace).
        this_target_namespace = pctxt.constructor.bucket.orig_target_namespace
        if namespace_name
          # 1.1 If the namespace [attribute] is present, then its `actual value` must not
          # match the `actual value` of the enclosing <schema>'s targetNamespace [attribute].
          if this_target_namespace == namespace_name
            p_custom_err(pctxt, ErrCode::SCHEMAP_SRC_IMPORT_1_1, nil, node,
              "The value of the attribute 'namespace' must not match " \
              "the target namespace '%s' of the importing schema", this_target_namespace)
            return pctxt.err
          end
        elsif this_target_namespace.nil?
          # 1.2 If the namespace [attribute] is not present, then the enclosing <schema> must
          # have a targetNamespace [attribute].
          p_custom_err(pctxt, ErrCode::SCHEMAP_SRC_IMPORT_1_2, nil, node,
            "The attribute 'namespace' must be existent if " \
            "the importing schema has no target namespace", nil)
          return pctxt.err
        end
        # Locate and acquire the schema document.
        schema_location = build_absolute_uri(pctxt.dict, schema_location, node) if schema_location
        ret, bucket = add_schema_doc(pctxt, XML_SCHEMA_SCHEMA_IMPORT, schema_location, nil, nil, 0,
          node, this_target_namespace, namespace_name)

        return ret if ret != 0

        # For <import>: "It is *not* an error for the application schema reference strategy
        # to fail." So just don't parse if no schema document was found. Note that we will
        # get no bucket if the schema could not be located or if there was no schemaLocation.
        if bucket.nil? && schema_location
          custom_warning(pctxt, ErrCode::SCHEMAP_WARN_UNLOCATED_SCHEMA, node, nil,
            "Failed to locate a schema at location '%s'. " \
            "Skipping the import", schema_location, nil, nil)
        end

        ret = parse_new_doc(pctxt, schema, bucket) if bucket && can_parse_schema(bucket)

        ret
      end

      INCLUDE_ALLOWED_ATTRS = %w[id schemaLocation].freeze

      # xmlSchemaParseIncludeOrRedefineAttrs
      # Returns [ret, schema_location]
      def parse_include_or_redefine_attrs(pctxt, schema, node, type)
        return [-1, nil] if pctxt.nil? || schema.nil? || node.nil?

        schema_location = nil
        # Check for illegal attributes. Applies for both <include> and <redefine>.
        p_check_illegal_attrs(pctxt, node, INCLUDE_ALLOWED_ATTRS)
        p_val_attr_id(pctxt, node, "id")
        # Preliminary step, extract the URI-Reference and make an URI from the base.
        # Attribute "schemaLocation" is mandatory.
        attr = get_prop_node(node, "schemaLocation")
        if attr
          r, schema_location = p_val_attr_node(pctxt, nil, attr,
            Types.get_built_in_type(XML_SCHEMAS_ANYURI))
          return [pctxt.err, schema_location] if r != 0

          base = Tree.node_get_base(node.doc, node)
          uri = if base.nil?
            URI_.build_uri(schema_location, node.doc&.url)
          else
            URI_.build_uri(schema_location, base)
          end
          if uri.nil?
            internal_err(pctxt, "xmlSchemaParseIncludeOrRedefine",
              "could not build an URI from the schemaLocation")
            return [-1, schema_location]
          end
          schema_location = uri
        else
          p_missing_attr_err(pctxt, ErrCode::SCHEMAP_S4S_ATTR_MISSING, nil, node, "schemaLocation", nil)
          return [pctxt.err, schema_location]
        end
        # Report self-inclusion and self-redefinition.
        if schema_location == pctxt.url
          if type == XML_SCHEMA_SCHEMA_REDEFINE
            p_custom_err(pctxt, ErrCode::SCHEMAP_SRC_REDEFINE, nil, node,
              "The schema document '%s' cannot redefine itself.", schema_location)
          else
            p_custom_err(pctxt, ErrCode::SCHEMAP_SRC_INCLUDE, nil, node,
              "The schema document '%s' cannot include itself.", schema_location)
          end
          return [pctxt.err, schema_location]
        end

        [0, schema_location]
      end

      # xmlSchemaParseIncludeOrRedefine
      def parse_include_or_redefine(pctxt, schema, node, type)
        return -1 if pctxt.nil? || schema.nil? || node.nil?

        is_chameleon = false
        was_chameleon = false
        # Parse attributes. Note that the returned schemaLocation will be already converted
        # to an absolute URI.
        res, schema_location = parse_include_or_redefine_attrs(pctxt, schema, node, type)
        return res if res != 0

        # Load and add the schema document.
        res, bucket = add_schema_doc(pctxt, type, schema_location, nil, nil, 0, node,
          pctxt.target_namespace, nil)
        return res if res != 0

        # If we get no schema bucket back, then this means that the schema document could not
        # be located or was broken XML or was not a schema document.
        if bucket.nil? || bucket.doc.nil?
          if type == XML_SCHEMA_SCHEMA_INCLUDE
            # WARNING for <include>: We will raise an error if the schema cannot be located
            # for inclusions, since the that was the feedback from the schema people.
            res = ErrCode::SCHEMAP_SRC_INCLUDE
            custom_err(pctxt, res, node, nil,
              "Failed to load the document '%s' for inclusion", schema_location, nil)
          else
            # NOTE: This was changed to raise an error even if no redefinitions are
            # specified. SPEC src-redefine (1)
            res = ErrCode::SCHEMAP_SRC_REDEFINE
            custom_err(pctxt, res, node, nil,
              "Failed to load the document '%s' for redefinition", schema_location, nil)
          end
        else
          # Check targetNamespace sanity before parsing the new schema.
          # TODO: Note that we won't check further content if the targetNamespace was bad.
          if bucket.orig_target_namespace
            # SPEC src-include (2.1)
            if pctxt.target_namespace.nil?
              custom_err(pctxt, ErrCode::SCHEMAP_SRC_INCLUDE, node, nil,
                "The target namespace of the included/redefined schema " \
                "'%s' has to be absent, since the including/redefining " \
                "schema has no target namespace", schema_location, nil)
              return pctxt.err # exit_error
            elsif bucket.orig_target_namespace != pctxt.target_namespace
              # TODO: Change error function.
              p_custom_err_ext(pctxt, ErrCode::SCHEMAP_SRC_INCLUDE, nil, node,
                "The target namespace '%s' of the included/redefined " \
                "schema '%s' differs from '%s' of the " \
                "including/redefining schema",
                bucket.orig_target_namespace, schema_location, pctxt.target_namespace)
              return pctxt.err # exit_error
            end
          elsif pctxt.target_namespace
            # Chameleons: the original target namespace will differ from the resulting
            # namespace.
            is_chameleon = true
            bucket.target_namespace = pctxt.target_namespace
          end
        end
        # Parse the schema.
        if bucket && bucket.parsed == 0 && bucket.doc
          if is_chameleon
            # TODO: Get rid of this flag on the schema itself.
            if (schema.flags & XML_SCHEMAS_INCLUDING_CONVERT_NS) == 0
              schema.flags |= XML_SCHEMAS_INCLUDING_CONVERT_NS
            else
              was_chameleon = true
            end
          end
          parse_new_doc(pctxt, schema, bucket)
          # Restore chameleon flag.
          schema.flags ^= XML_SCHEMAS_INCLUDING_CONVERT_NS if is_chameleon && !was_chameleon
        end
        # And now for the children...
        child = node.children
        if type == XML_SCHEMA_SCHEMA_REDEFINE
          # Parse (simpleType | complexType | group | attributeGroup))*
          pctxt.redefined = bucket
          # How to proceed if the redefined schema was not located?
          pctxt.is_redefine = 1
          while is_schema(child, "annotation") || is_schema(child, "simpleType") ||
              is_schema(child, "complexType") || is_schema(child, "group") ||
              is_schema(child, "attributeGroup")
            if is_schema(child, "annotation")
              # TODO: discard or not?
            elsif is_schema(child, "simpleType")
              parse_simple_type(pctxt, schema, child, 1)
            elsif is_schema(child, "complexType")
              parse_complex_type(pctxt, schema, child, 1)
            elsif is_schema(child, "group")
              parse_model_group_definition(pctxt, schema, child)
            elsif is_schema(child, "attributeGroup")
              parse_attribute_group_definition(pctxt, schema, child)
            end
            child = child.next
          end
          pctxt.redefined = nil
          pctxt.is_redefine = 0
        elsif is_schema(child, "annotation")
          # TODO: discard or not?
          child = child.next
        end
        if child
          res = ErrCode::SCHEMAP_S4S_ELEM_NOT_ALLOWED
          if type == XML_SCHEMA_SCHEMA_REDEFINE
            p_content_err(pctxt, res, nil, node, child, nil,
              "(annotation | (simpleType | complexType | group | attributeGroup))*")
          else
            p_content_err(pctxt, res, nil, node, child, nil, "(annotation?)")
          end
        end
        res
      end

      # xmlSchemaParseRedefine
      def parse_redefine(pctxt, schema, node)
        res = parse_include_or_redefine(pctxt, schema, node, XML_SCHEMA_SCHEMA_REDEFINE)
        return res if res != 0

        0
      end

      # xmlSchemaParseInclude
      def parse_include(pctxt, schema, node)
        res = parse_include_or_redefine(pctxt, schema, node, XML_SCHEMA_SCHEMA_INCLUDE)
        return res if res != 0

        0
      end

      # ------------------------------------------------------------------------------------
      # Reading/Writing Schemas
      # ------------------------------------------------------------------------------------

      # xmlSchemaParserCtxtSetOptions (#if 0 in libxml2; kept for completeness)
      def parser_ctxt_set_options(ctxt, options)
        return -1 if ctxt.nil?

        # WARNING: Change the start value if adding to the xmlSchemaParseOption.
        (1...32).each do |i|
          return -1 if (options & (1 << i)) != 0
        end
        ctxt.options = options
        0
      end

      # xmlSchemaParserCtxtGetOptions (#if 0 in libxml2; kept for completeness)
      def parser_ctxt_get_options(ctxt)
        return -1 if ctxt.nil?

        ctxt.options
      end

      # xmlSchemaNewParserCtxt: Create an XML Schemas parse context for that file/resource
      # expected to contain an XML Schemas file.
      def new_parser_ctxt(url)
        return nil if url.nil?

        ret = parser_ctxt_create
        ret.dict = nil # xmlDictCreate(): dictionaries are irrelevant in Ruby
        ret.url = url
        ret
      end

      # xmlSchemaNewMemParserCtxt: Create an XML Schemas parse context for that memory buffer
      # expected to contain an XML Schemas file.
      def new_mem_parser_ctxt(buffer, size)
        return nil if buffer.nil? || size <= 0

        ret = parser_ctxt_create
        ret.buffer = buffer
        ret.size = size
        ret.dict = nil
        ret
      end

      # xmlSchemaNewDocParserCtxt: Create an XML Schemas parse context for that document.
      # NB. The document may be modified during the parsing process.
      def new_doc_parser_ctxt(doc)
        return nil if doc.nil?

        ret = parser_ctxt_create
        ret.doc = doc
        ret.dict = nil
        # The application has responsibility for the document
        ret.preserve = 1
        ret
      end

      # xmlSchemaFreeParserCtxt (no-op: garbage collected)
      def free_parser_ctxt(_ctxt) = nil
    end
  end
end
