# frozen_string_literal: true

require_relative "macros"
require_relative "pattern"

# Identity-constraint (xs:unique / xs:key / xs:keyref) validation of libxml2 2.13.9 xmlschemas.c
# (lines ~21860-23850): augmented IDCs, XPath state objects, key sequences, node tables,
# bubbling and keyref resolution.
module Nokogiri
  module Pure
    module Schemas
      # xmlSchemaVAddNodeQName
      def v_add_node_q_name(vctxt, lname, nsname)
        items = vctxt.node_qnames.items
        i = 0
        while i < items.size
          return i if items[i] == lname && items[i + 1] == nsname

          i += 2
        end
        i = items.size
        items << lname << nsname
        i
      end

      # xmlSchemaAugmentIDC
      def augment_idc(idc_def, vctxt)
        aidc = SchemaIDCAug.new(def: idc_def, keyref_depth: -1)
        aidc.next = vctxt.aidcs
        vctxt.aidcs = aidc
        vctxt.has_keyrefs = 1 if vctxt.has_keyrefs == 0 && idc_def.type == XML_SCHEMA_TYPE_IDC_KEYREF
      end

      # xmlSchemaAugmentImportedIDC
      def augment_imported_idc(imported, vctxt)
        return if imported.schema.nil? || imported.schema.idc_def.nil?

        imported.schema.idc_def.each_value { |idc| augment_idc(idc, vctxt) }
      end

      # xmlSchemaIDCNewBinding
      def idc_new_binding(idc_def)
        PSVIIDCBinding.new(definition: idc_def, node_table: nil)
      end

      # xmlSchemaIDCStoreNodeTableItem
      def idc_store_node_table_item(vctxt, item)
        (vctxt.idc_nodes ||= []) << item
        0
      end

      # xmlSchemaIDCStoreKey
      def idc_store_key(vctxt, key)
        (vctxt.idc_keys ||= []) << key
        0
      end

      # xmlSchemaIDCAppendNodeTableItem
      def idc_append_node_table_item(bind, nt_item)
        (bind.node_table ||= []) << nt_item
        0
      end

      def binding_nb_nodes(bind) = bind.node_table ? bind.node_table.size : 0

      # xmlSchemaIDCAcquireBinding
      def idc_acquire_binding(vctxt, matcher)
        ielem = vctxt.elem_infos[matcher.depth]
        if ielem.idc_table.nil?
          ielem.idc_table = idc_new_binding(matcher.aidc.def)
          return ielem.idc_table
        end
        bind = ielem.idc_table
        while bind
          return bind if bind.definition.equal?(matcher.aidc.def)

          if bind.next.nil?
            bind.next = idc_new_binding(matcher.aidc.def)
            return bind.next
          end
          bind = bind.next
        end
        nil
      end

      # xmlSchemaIDCAcquireTargetList
      def idc_acquire_target_list(_vctxt, matcher)
        matcher.targets ||= SchemaItemList.new
      end

      # xmlSchemaIDCReleaseMatcherList (no matcher cache in Ruby: just drop them)
      def idc_release_matcher_list(_vctxt, matcher)
        while matcher
          nxt = matcher.next
          matcher.key_seqs = nil
          matcher.targets = nil
          matcher.htab = nil
          matcher.next = nil
          matcher = nxt
        end
      end

      # xmlSchemaIDCAddStateObject
      def idc_add_state_object(vctxt, matcher, sel, type)
        sto = IDCStateObj.new(history: [])
        sto.next = vctxt.xpath_states
        vctxt.xpath_states = sto
        sto.xpath_ctxt = pattern_get_stream_ctxt(sel.xpath_comp)
        if sto.xpath_ctxt.nil?
          internal_err(vctxt, "xmlSchemaIDCAddStateObject",
            "failed to create an XPath validation context")
          return -1
        end
        sto.type = type
        sto.depth = vctxt.depth
        sto.matcher = matcher
        sto.sel = sel
        0
      end

      # xmlSchemaXPathEvaluate
      def x_path_evaluate(vctxt, node_type)
        return 0 if vctxt.xpath_states.nil?

        resolved = 0
        depth = vctxt.depth
        depth += 1 if node_type == ATTRIBUTE_NODE
        head = nil
        first = vctxt.xpath_states
        sto = first
        inode = vctxt.inode
        while !sto.equal?(head)
          res = if node_type == ELEMENT_NODE
            Pattern.stream_push(sto.xpath_ctxt, inode.local_name, inode.ns_name)
          else
            Pattern.stream_push_attr(sto.xpath_ctxt, inode.local_name, inode.ns_name)
          end
          if res == -1
            internal_err(vctxt, "xmlSchemaXPathEvaluate", "calling xmlStreamPush()")
            return -1
          end
          if res != 0
            sto.history << depth
            if sto.type == XPATH_STATE_OBJ_TYPE_IDC_SELECTOR
              sel = sto.matcher.aidc.def.fields
              while sel
                return -1 if idc_add_state_object(vctxt, sto.matcher, sel, XPATH_STATE_OBJ_TYPE_IDC_FIELD) == -1

                sel = sel.next
              end
            elsif sto.type == XPATH_STATE_OBJ_TYPE_IDC_FIELD
              if resolved == 0 && (inode.flags & XML_SCHEMA_NODE_INFO_VALUE_NEEDED) == 0
                inode.flags |= XML_SCHEMA_NODE_INFO_VALUE_NEEDED
              end
              resolved += 1
            end
          end
          # next_sto:
          if sto.next.nil?
            head = first
            sto = vctxt.xpath_states
          else
            sto = sto.next
          end
        end
        resolved
      end

      # xmlSchemaFormatIDCKeySequence_1
      def format_idc_key_sequence_1(vctxt, seq, count, for_hash)
        buf = +"["
        count.times do |i|
          buf << "'"
          res, value = if !for_hash
            get_canon_value_whtsp_ext(seq[i].val, get_white_space_facet_value(seq[i].type))
          else
            get_canon_value_hash(seq[i].val)
          end
          if res == 0
            buf << value.to_s
          else
            internal_err(vctxt, "xmlSchemaFormatIDCKeySequence", "failed to compute a canonical value")
            buf << "???"
          end
          buf << (i < count - 1 ? "', " : "'")
        end
        buf << "]"
      end

      # xmlSchemaFormatIDCKeySequence
      def format_idc_key_sequence(vctxt, seq, count) = format_idc_key_sequence_1(vctxt, seq, count, false)

      # xmlSchemaHashKeySequence
      def hash_key_sequence(vctxt, seq, count) = format_idc_key_sequence_1(vctxt, seq, count, true)

      # xmlSchemaXPathPop
      def x_path_pop(vctxt)
        sto = vctxt.xpath_states
        while sto
          return -1 if Pattern.stream_pop(sto.xpath_ctxt) == -1

          sto = sto.next
        end
        0
      end

      # xmlSchemaXPathProcessHistory
      def x_path_process_history(vctxt, depth)
        return 0 if vctxt.xpath_states.nil?

        key = nil
        type = vctxt.inode.type_def
        simple_type = nil
        sto = vctxt.xpath_states
        while sto
          if Pattern.stream_pop(sto.xpath_ctxt) == -1
            internal_err(vctxt, "xmlSchemaXPathProcessHistory", "calling xmlStreamPop()")
            return -1
          end
          unless sto.history.empty?
            match_depth = sto.history[-1]
            if match_depth != depth
              sto = sto.next
              next
            end
          end
          catch(:deregister_check) do
            throw :deregister_check if sto.history.empty?

            if sto.type == XPATH_STATE_OBJ_TYPE_IDC_FIELD
              if type && wxs_is_complex(type)
                if wxs_has_simple_content(type)
                  simple_type = type.content_type_def
                  if simple_type.nil?
                    internal_err(vctxt, "xmlSchemaXPathProcessHistory",
                      "field resolves to a CT with simple content but the CT is missing the ST definition")
                    return -1
                  end
                else
                  simple_type = nil
                end
              else
                simple_type = type
              end
              if simple_type.nil?
                custom_err(vctxt, ErrCode::SCHEMAV_CVC_IDC, nil, sto.matcher.aidc.def,
                  "The XPath '%s' of a field of %s does evaluate to a node of non-simple type",
                  sto.sel.xpath, get_idc_designation(sto.matcher.aidc.def))
                sto.history.pop
                throw :deregister_check
              end
              if key.nil? && vctxt.inode.val.nil?
                custom_err(vctxt, ErrCode::SCHEMAV_CVC_IDC, nil, sto.matcher.aidc.def,
                  "Warning: No precomputed value available, the value was either invalid or " \
                  "something strange happened", nil, nil)
                sto.history.pop
                throw :deregister_check
              else
                matcher = sto.matcher
                pos = sto.depth - matcher.depth
                idx = sto.sel.index
                matcher.key_seqs ||= []
                key_seq = matcher.key_seqs[pos]
                if key_seq.nil?
                  key_seq = Array.new(matcher.aidc.def.nb_fields)
                  matcher.key_seqs[pos] = key_seq
                elsif !key_seq[idx].nil?
                  custom_err(vctxt, ErrCode::SCHEMAV_CVC_IDC, nil, matcher.aidc.def,
                    "The XPath '%s' of a field of %s evaluates to a node-set with more than one member",
                    sto.sel.xpath, get_idc_designation(matcher.aidc.def))
                  sto.history.pop
                  throw :deregister_check
                end
                # create_key:
                if key.nil?
                  key = PSVIIDCKey.new(type: simple_type, val: vctxt.inode.val)
                  vctxt.inode.val = nil
                  idc_store_key(vctxt, key)
                end
                key_seq[idx] = key
              end
            elsif sto.type == XPATH_STATE_OBJ_TYPE_IDC_SELECTOR
              matcher = sto.matcher
              idc = matcher.aidc.def
              nb_keys = idc.nb_fields
              pos = depth - matcher.depth
              key_seq = nil
              catch(:selector_leave) do
                key_error = false
                if matcher.key_seqs.nil? || matcher.key_seqs.size <= pos || (key_seq = matcher.key_seqs[pos]).nil?
                  key_error = idc.type == XML_SCHEMA_TYPE_IDC_KEY
                  throw :selector_leave unless key_error
                end
                unless key_error
                  nb_keys.times do |i|
                    next unless key_seq[i].nil?

                    throw :selector_leave unless idc.type == XML_SCHEMA_TYPE_IDC_KEY

                    key_error = true
                    break
                  end
                end
                if key_error
                  # selector_key_error:
                  custom_err(vctxt, ErrCode::SCHEMAV_CVC_IDC, nil, idc,
                    "Not all fields of %s evaluate to a node", get_idc_designation(idc), nil)
                  throw :selector_leave
                end
                targets = idc_acquire_target_list(vctxt, matcher)
                if idc.type != XML_SCHEMA_TYPE_IDC_KEYREF && targets.nb_items != 0
                  res = 0
                  e = matcher.htab ? matcher.htab[hash_key_sequence(vctxt, key_seq, nb_keys)] : nil
                  found = false
                  e&.each do |index|
                    bkey_seq = targets.items[index].keys
                    nb_keys.times do |j|
                      res = are_values_equal(key_seq[j].val, bkey_seq[j].val)
                      return -1 if res == -1
                      break if res == 0
                    end
                    if res == 1
                      found = true
                      break
                    end
                  end
                  if found
                    custom_err(vctxt, ErrCode::SCHEMAV_CVC_IDC, nil, idc,
                      "Duplicate key-sequence %s in %s",
                      format_idc_key_sequence(vctxt, key_seq, nb_keys),
                      get_idc_designation(idc))
                    throw :selector_leave
                  end
                end
                nt_item = PSVIIDCNode.new
                if idc.type != XML_SCHEMA_TYPE_IDC_KEYREF
                  idc_store_node_table_item(vctxt, nt_item)
                  nt_item.node_qname_id = -1
                else
                  nt_item.node_qname_id = v_add_node_q_name(vctxt, vctxt.inode.local_name, vctxt.inode.ns_name)
                end
                nt_item.node = vctxt.node
                nt_item.node_line = vctxt.inode.node_line
                nt_item.keys = key_seq
                matcher.key_seqs[pos] = nil
                key_seq = nil
                targets.items << nt_item
                if idc.type != XML_SCHEMA_TYPE_IDC_KEYREF
                  matcher.htab ||= {}
                  value = hash_key_sequence(vctxt, nt_item.keys, nb_keys)
                  index = targets.nb_items - 1
                  r = matcher.htab[value]
                  if r
                    r.insert(1, index)
                  else
                    matcher.htab[value] = [index]
                  end
                end
              end
              # selector_leave:
              matcher.key_seqs[pos] = nil if key_seq && matcher.key_seqs
            end
            sto.history.pop
          end
          # deregister_check:
          if sto.history.empty? && sto.depth == depth
            unless vctxt.xpath_states.equal?(sto)
              internal_err(vctxt, "xmlSchemaXPathProcessHistory",
                "The state object to be removed is not the first in the list")
            end
            nextsto = sto.next
            vctxt.xpath_states = sto.next
            sto = nextsto
          else
            sto = sto.next
          end
        end
        0
      end

      # xmlSchemaIDCRegisterMatchers
      def idc_register_matchers(vctxt, elem_decl)
        idc = elem_decl.idcs
        return 0 if idc.nil?

        unless vctxt.inode.idc_matchers.nil?
          internal_err(vctxt, "xmlSchemaIDCRegisterMatchers",
            "The chain of IDC matchers is expected to be empty")
          return -1
        end
        last = nil
        while idc
          if idc.type == XML_SCHEMA_TYPE_IDC_KEYREF
            ref_idc = idc.ref.item
            if ref_idc
              vctxt.inode.has_keyrefs = 1
              aidc = vctxt.aidcs
              aidc = aidc.next while aidc && !aidc.def.equal?(ref_idc)
              if aidc.nil?
                internal_err(vctxt, "xmlSchemaIDCRegisterMatchers",
                  "Could not find an augmented IDC item for an IDC definition")
                return -1
              end
              if aidc.keyref_depth == -1 || vctxt.depth < aidc.keyref_depth
                aidc.keyref_depth = vctxt.depth
              end
            end
          end
          aidc = vctxt.aidcs
          aidc = aidc.next while aidc && !aidc.def.equal?(idc)
          if aidc.nil?
            internal_err(vctxt, "xmlSchemaIDCRegisterMatchers",
              "Could not find an augmented IDC item for an IDC definition")
            return -1
          end
          matcher = IDCMatcher.new
          if last.nil?
            vctxt.inode.idc_matchers = matcher
          else
            last.next = matcher
          end
          last = matcher
          matcher.type = IDC_MATCHER
          matcher.depth = vctxt.depth
          matcher.aidc = aidc
          matcher.idc_type = aidc.def.type
          return -1 if idc_add_state_object(vctxt, matcher, idc.selector, XPATH_STATE_OBJ_TYPE_IDC_SELECTOR) == -1

          idc = idc.next
        end
        0
      end

      # compare two key sequences (all fields); returns 1 equal, 0 not, -1 error
      def idc_keys_equal(keys, ntkeys, nb_fields)
        if nb_fields == 1
          return are_values_equal(keys[0].val, ntkeys[0].val)
        end

        res = 0
        nb_fields.times do |k|
          res = are_values_equal(keys[k].val, ntkeys[k].val)
          return res if res == -1 || res == 0
        end
        res
      end

      # xmlSchemaIDCFillNodeTables
      def idc_fill_node_tables(vctxt, ielem)
        matcher = ielem.idc_matchers
        while matcher
          if matcher.aidc.def.type == XML_SCHEMA_TYPE_IDC_KEYREF || wxs_ilist_is_empty(matcher.targets)
            matcher = matcher.next
            next
          end
          if vctxt.create_idc_node_tables == 0 &&
              (matcher.aidc.keyref_depth == -1 || matcher.aidc.keyref_depth > vctxt.depth)
            matcher = matcher.next
            next
          end
          bind = idc_acquire_binding(vctxt, matcher)
          return -1 if bind.nil?

          if !wxs_ilist_is_empty(bind.dupls)
            dupls = bind.dupls.items
            nb_dupls = dupls.size
          else
            dupls = nil
            nb_dupls = 0
          end
          nb_node_table = binding_nb_nodes(bind)
          if nb_node_table == 0 && nb_dupls == 0
            bind.node_table = matcher.targets.items
            matcher.targets.items = []
            matcher.htab = nil
          else
            targets = matcher.targets.items
            nb_targets = targets.size
            nb_fields = matcher.aidc.def.nb_fields
            i = 0
            while i < nb_targets
              keys = targets[i].keys
              catch(:next_target) do
                if nb_dupls > 0
                  j = 0
                  while j < nb_dupls
                    res = idc_keys_equal(keys, dupls[j].keys, nb_fields)
                    return -1 if res == -1
                    throw :next_target if res == 1

                    j += 1
                  end
                end
                nodes = bind.node_table
                if nodes && !nodes.empty?
                  j = 0
                  while j < nodes.size
                    res = idc_keys_equal(keys, nodes[j].keys, nb_fields)
                    return -1 if res == -1

                    if res == 1
                      bind.dupls ||= SchemaItemList.new
                      bind.dupls.items << nodes[j]
                      dupls = bind.dupls.items
                      nodes[j] = nodes[-1]
                      nodes.pop
                      throw :next_target
                    end
                    j += 1
                  end
                end
                idc_append_node_table_item(bind, targets[i])
              end
              i += 1
            end
          end
          matcher = matcher.next
        end
        0
      end

      # xmlSchemaBubbleIDCNodeTables
      def bubble_idc_node_tables(vctxt)
        bind = vctxt.inode.idc_table
        return 0 if bind.nil?

        parent_info = vctxt.elem_infos[vctxt.depth - 1]
        while bind
          catch(:next_binding) do
            throw :next_binding if binding_nb_nodes(bind) == 0 && wxs_ilist_is_empty(bind.dupls)

            if vctxt.create_idc_node_tables == 0
              aidc = vctxt.aidcs
              while aidc
                if aidc.def.equal?(bind.definition)
                  throw :next_binding if aidc.keyref_depth == -1 || aidc.keyref_depth >= vctxt.depth

                  break
                end
                aidc = aidc.next
              end
            end
            par_bind = parent_info&.idc_table
            par_bind = par_bind.next while par_bind && !par_bind.definition.equal?(bind.definition)

            if par_bind
              old_num = binding_nb_nodes(par_bind)
              if !wxs_ilist_is_empty(par_bind.dupls)
                old_dupls = par_bind.dupls.nb_items
                dupls = par_bind.dupls.items
              else
                dupls = nil
                old_dupls = 0
              end
              par_bind.node_table ||= []
              par_nodes = par_bind.node_table
              nb_fields = bind.definition.nb_fields
              bind_nodes = bind.node_table || []
              i = 0
              while i < bind_nodes.size
                node = bind_nodes[i]
                i += 1
                next if node.nil?

                if old_dupls > 0
                  j = 0
                  while j < old_dupls
                    ret = idc_keys_equal(node.keys, dupls[j].keys, nb_fields)
                    return -1 if ret == -1
                    break if ret == 1

                    j += 1
                  end
                  next if j != old_dupls
                end
                if old_num > 0
                  j = 0
                  par_node = nil
                  while j < old_num
                    par_node = par_nodes[j]
                    ret = idc_keys_equal(node.keys, par_node.keys, nb_fields)
                    return -1 if ret == -1
                    break if ret == 1

                    j += 1
                  end
                  if j != old_num
                    old_num -= 1
                    last = par_nodes.size - 1
                    par_nodes[j] = par_nodes[old_num]
                    par_nodes[old_num] = par_nodes[last] if last != old_num
                    par_nodes.pop
                    par_bind.dupls ||= SchemaItemList.new
                    par_bind.dupls.items << par_node
                    dupls = par_bind.dupls.items
                  else
                    par_nodes << node
                  end
                else
                  par_nodes << node
                end
              end
            else
              par_bind = idc_new_binding(bind.definition)
              if binding_nb_nodes(bind) != 0
                if vctxt.psvi_expose_idc_node_tables == 0
                  par_bind.node_table = bind.node_table
                  bind.node_table = nil
                else
                  par_bind.node_table = bind.node_table.dup
                end
              end
              if bind.dupls
                par_bind.dupls = bind.dupls
                bind.dupls = nil
              end
              if parent_info
                par_bind.next = parent_info.idc_table
                parent_info.idc_table = par_bind
              end
            end
          end
          bind = bind.next
        end
        0
      end

      # xmlSchemaCheckCVCIDCKeyRef
      def check_cvcidc_key_ref(vctxt)
        matcher = vctxt.inode.idc_matchers
        while matcher
          if matcher.idc_type == XML_SCHEMA_TYPE_IDC_KEYREF && matcher.targets && matcher.targets.nb_items > 0
            nb_fields = matcher.aidc.def.nb_fields
            bind = vctxt.inode.idc_table
            bind = bind.next while bind && !matcher.aidc.def.ref.item.equal?(bind.definition)
            has_dupls = bind && bind.dupls && bind.dupls.nb_items > 0
            table = nil
            if bind
              table = {}
              (bind.node_table || []).each_with_index do |nt, j|
                value = hash_key_sequence(vctxt, nt.keys, nb_fields)
                r = table[value]
                if r
                  r.insert(1, j)
                else
                  table[value] = [j]
                end
              end
            end
            matcher.targets.items.each do |ref_node|
              res = 0
              if bind
                ref_keys = ref_node.keys
                e = table[hash_key_sequence(vctxt, ref_keys, nb_fields)]
                res = 0
                e&.each do |index|
                  keys = bind.node_table[index].keys
                  nb_fields.times do |k|
                    res = are_values_equal(keys[k].val, ref_keys[k].val)
                    break if res == 0
                    return -1 if res == -1
                  end
                  break if res == 1
                end
                if res == 0 && has_dupls
                  bind.dupls.items.each do |dup|
                    keys = dup.keys
                    nb_fields.times do |k|
                      res = are_values_equal(keys[k].val, ref_keys[k].val)
                      break if res == 0
                      return -1 if res == -1
                    end
                    next unless res == 1

                    keyref_err(vctxt, ErrCode::SCHEMAV_CVC_IDC, ref_node, matcher.aidc.def,
                      "More than one match found for key-sequence %s of keyref '%s'",
                      format_idc_key_sequence(vctxt, ref_node.keys, nb_fields),
                      get_component_q_name(matcher.aidc.def))
                    break
                  end
                end
              end
              if res == 0
                keyref_err(vctxt, ErrCode::SCHEMAV_CVC_IDC, ref_node, matcher.aidc.def,
                  "No match found for key-sequence %s of keyref '%s'",
                  format_idc_key_sequence(vctxt, ref_node.keys, nb_fields),
                  get_component_q_name(matcher.aidc.def))
              end
            end
          end
          matcher = matcher.next
        end
        0
      end
    end
  end
end
