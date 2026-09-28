# frozen_string_literal: true

# Port of libexslt/common.c: exsl:node-set(), exsl:object-type() and the exsl:document element.

module Nokogiri
  module Pure
    module XSLT
      module EXSLT
        module_function

        # exsltNodeSetFunction
        def node_set_function(ctxt, nargs)
          if nargs != 1
            ctxt.xpath_err(XPath::INVALID_ARITY)
            return
          end
          if stack_is_node_set?(ctxt)
            XSLT.function_node_set(ctxt, nargs)
            return
          end

          # SPEC EXSLT: "You can also use this function to turn a string into a text node,
          # which is helpful if you want to pass a string to a function that only accepts a
          # node-set."
          tctxt = XSLT.xpath_get_transform_context(ctxt)
          fragment = XSLT.create_rvt(tctxt)
          if fragment.nil?
            XSLT.transform_error(tctxt, nil, tctxt.inst,
              "exsltNodeSetFunction: Failed to create a tree fragment.\n")
            tctxt.state = XSLT::STATE_STOPPED
            return
          end
          XSLT.register_local_rvt(tctxt, fragment)

          strval = ctxt.pop_string
          txt = Tree.new_doc_text(fragment, strval)
          Tree.add_child(fragment, txt)
          ctxt.value_push(XPath.node_set_create(txt))
        end

        # exsltObjectTypeFunction
        def object_type_function(ctxt, nargs)
          if nargs != 1
            ctxt.xpath_err(XPath::INVALID_ARITY)
            return
          end

          obj = ctxt.value_pop
          ret = case obj
          when String then +"string"
          when Float then +"number"
          when true, false then +"boolean"
          when XPath::ValueTree then +"RTF"
          when Array then +"node-set"
          when XPath::UserObject then +"external"
          else
            XSLT.generic_error("object-type() invalid arg\n")
            ctxt.error = XPath::INVALID_TYPE
            return
          end
          ctxt.value_push(ret)
        end

        # exsltCommonRegister
        def common_register
          XSLT.register_ext_module_function("node-set", COMMON_NAMESPACE, method(:node_set_function))
          XSLT.register_ext_module_function("object-type", COMMON_NAMESPACE, method(:object_type_function))
          XSLT.register_ext_module_element("document", COMMON_NAMESPACE,
            ->(style, inst, function) { XSLT.document_comp(style, inst, function) },
            ->(ctxt, node, inst, comp) { XSLT.document_elem(ctxt, node, inst, comp) })
        end
      end
    end
  end
end
