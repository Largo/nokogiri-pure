# frozen_string_literal: true

require_relative "structs"
require_relative "macros"
require_relative "common"

# Port of xmlschemas.c "Building the content models" (xmlSchemaBuildContentModel* and
# xmlSchemaBuildAContentModel). The order of the automaton construction calls is kept exactly
# as in C: it determines state numbering, hence the "Expected is ( ... )" lists and the
# determinism result.
module Nokogiri
  module Pure
    module Schemas
      extend self

      # xmlSchemaBuildContentModelForSubstGroup
      # Returns 1 if nillable, 0 otherwise
      def build_content_model_for_subst_group(pctxt, particle, counter, end_)
        am = pctxt.am
        ret = 0
        elem_decl = particle.children
        # Wrap the substitution group with a CHOICE.
        start = pctxt.state
        end_ = XmlRegexp.automata_new_state(am) if end_.nil?
        subst_group = subst_group_get(pctxt, elem_decl)
        if subst_group.nil?
          p_err(pctxt, get_component_node(particle),
            ErrCode::SCHEMAP_INTERNAL,
            "Internal error: xmlSchemaBuildContentModelForSubstGroup, " \
            "declaration is marked having a subst. group but none " \
            "available.\n", elem_decl.name, nil)
          return 0
        end
        members = subst_group.members.items
        if counter >= 0
          # NOTE that we put the declaration in, even if it's abstract.
          tmp = XmlRegexp.automata_new_counted_trans(am, start, nil, counter)
          XmlRegexp.automata_new_transition2(am, tmp, end_,
            elem_decl.name, elem_decl.target_namespace, elem_decl)
          # Add subst. group members.
          members.each do |member|
            XmlRegexp.automata_new_transition2(am, tmp, end_,
              member.name, member.target_namespace, member)
          end
        elsif particle.max_occurs == 1
          XmlRegexp.automata_new_epsilon(am,
            XmlRegexp.automata_new_transition2(am, start, nil,
              elem_decl.name, elem_decl.target_namespace, elem_decl), end_)
          members.each do |member|
            tmp = XmlRegexp.automata_new_transition2(am, start, nil,
              member.name, member.target_namespace, member)
            XmlRegexp.automata_new_epsilon(am, tmp, end_)
          end
        else
          max_occurs = particle.max_occurs == UNBOUNDED ? UNBOUNDED : particle.max_occurs - 1
          min_occurs = particle.min_occurs < 1 ? 0 : particle.min_occurs - 1

          counter = XmlRegexp.automata_new_counter(am, min_occurs, max_occurs)
          hop = XmlRegexp.automata_new_state(am)

          XmlRegexp.automata_new_epsilon(am,
            XmlRegexp.automata_new_transition2(am, start, nil,
              elem_decl.name, elem_decl.target_namespace, elem_decl), hop)
          members.each do |member|
            XmlRegexp.automata_new_epsilon(am,
              XmlRegexp.automata_new_transition2(am, start, nil,
                member.name, member.target_namespace, member), hop)
          end
          XmlRegexp.automata_new_counted_trans(am, hop, start, counter)
          XmlRegexp.automata_new_counter_trans(am, hop, end_, counter)
        end
        if particle.min_occurs == 0
          XmlRegexp.automata_new_epsilon(am, start, end_)
          ret = 1
        end
        pctxt.state = end_
        ret
      end

      # xmlSchemaBuildContentModelForElement
      # Returns 1 if nillable, 0 otherwise
      def build_content_model_for_element(ctxt, particle)
        ret = 0
        if (particle.children.flags & XML_SCHEMAS_ELEM_SUBST_GROUP_HEAD) != 0
          # Substitution groups.
          ret = build_content_model_for_subst_group(ctxt, particle, -1, nil)
        else
          am = ctxt.am
          elem_decl = particle.children
          return 0 if (elem_decl.flags & XML_SCHEMAS_ELEM_ABSTRACT) != 0

          if particle.max_occurs == 1
            start = ctxt.state
            ctxt.state = XmlRegexp.automata_new_transition2(am, start, nil,
              elem_decl.name, elem_decl.target_namespace, elem_decl)
          elsif particle.max_occurs >= UNBOUNDED && particle.min_occurs < 2
            # Special case.
            start = ctxt.state
            ctxt.state = XmlRegexp.automata_new_transition2(am, start, nil,
              elem_decl.name, elem_decl.target_namespace, elem_decl)
            ctxt.state = XmlRegexp.automata_new_transition2(am, ctxt.state, ctxt.state,
              elem_decl.name, elem_decl.target_namespace, elem_decl)
          else
            max_occurs = particle.max_occurs == UNBOUNDED ? UNBOUNDED : particle.max_occurs - 1
            min_occurs = particle.min_occurs < 1 ? 0 : particle.min_occurs - 1

            start = XmlRegexp.automata_new_epsilon(am, ctxt.state, nil)
            counter = XmlRegexp.automata_new_counter(am, min_occurs, max_occurs)
            ctxt.state = XmlRegexp.automata_new_transition2(am, start, nil,
              elem_decl.name, elem_decl.target_namespace, elem_decl)
            XmlRegexp.automata_new_counted_trans(am, ctxt.state, start, counter)
            ctxt.state = XmlRegexp.automata_new_counter_trans(am, ctxt.state, nil, counter)
          end
          if particle.min_occurs == 0
            XmlRegexp.automata_new_epsilon(am, start, ctxt.state)
            ret = 1
          end
        end
        ret
      end

      # xmlSchemaBuildAContentModel
      # Create the automaton for the {content type} of a complex type.
      # Returns 1 if the content is nillable, 0 otherwise
      def build_a_content_model(pctxt, particle)
        ret = 0
        if particle.nil?
          internal_err(pctxt, "xmlSchemaBuildAContentModel", "particle is NULL")
          return 1
        end
        # A missing "term" of the particle might arise due to an invalid "term" component.
        return 1 if particle.children.nil?

        am = pctxt.am
        case particle.children.type
        when XML_SCHEMA_TYPE_ANY
          wild = particle.children
          start = pctxt.state
          end_ = XmlRegexp.automata_new_state(am)

          if particle.max_occurs == 1
            if wild.any == 1
              # 1. the {"*", "*"} for elements in a namespace.
              pctxt.state = XmlRegexp.automata_new_transition2(am, start, nil, "*", "*", wild)
              XmlRegexp.automata_new_epsilon(am, pctxt.state, end_)
              # 2. the {"*"} for elements in no namespace.
              pctxt.state = XmlRegexp.automata_new_transition2(am, start, nil, "*", nil, wild)
              XmlRegexp.automata_new_epsilon(am, pctxt.state, end_)
            elsif !wild.ns_set.nil?
              ns = wild.ns_set
              loop do
                pctxt.state = start
                pctxt.state = XmlRegexp.automata_new_transition2(am, pctxt.state, nil, "*", ns.value, wild)
                XmlRegexp.automata_new_epsilon(am, pctxt.state, end_)
                ns = ns.next
                break if ns.nil?
              end
            elsif !wild.neg_ns_set.nil?
              pctxt.state = XmlRegexp.automata_new_neg_trans(am, start, end_, "*",
                wild.neg_ns_set.value, wild)
            end
          else
            max_occurs = particle.max_occurs == UNBOUNDED ? UNBOUNDED : particle.max_occurs - 1
            min_occurs = particle.min_occurs < 1 ? 0 : particle.min_occurs - 1

            counter = XmlRegexp.automata_new_counter(am, min_occurs, max_occurs)
            hop = XmlRegexp.automata_new_state(am)
            if wild.any == 1
              pctxt.state = XmlRegexp.automata_new_transition2(am, start, nil, "*", "*", wild)
              XmlRegexp.automata_new_epsilon(am, pctxt.state, hop)
              pctxt.state = XmlRegexp.automata_new_transition2(am, start, nil, "*", nil, wild)
              XmlRegexp.automata_new_epsilon(am, pctxt.state, hop)
            elsif !wild.ns_set.nil?
              ns = wild.ns_set
              loop do
                pctxt.state = XmlRegexp.automata_new_transition2(am, start, nil, "*", ns.value, wild)
                XmlRegexp.automata_new_epsilon(am, pctxt.state, hop)
                ns = ns.next
                break if ns.nil?
              end
            elsif !wild.neg_ns_set.nil?
              pctxt.state = XmlRegexp.automata_new_neg_trans(am, start, hop, "*",
                wild.neg_ns_set.value, wild)
            end
            XmlRegexp.automata_new_counted_trans(am, hop, start, counter)
            XmlRegexp.automata_new_counter_trans(am, hop, end_, counter)
          end
          if particle.min_occurs == 0
            XmlRegexp.automata_new_epsilon(am, start, end_)
            ret = 1
          end
          pctxt.state = end_
        when XML_SCHEMA_TYPE_ELEMENT
          ret = build_content_model_for_element(pctxt, particle)
        when XML_SCHEMA_TYPE_SEQUENCE
          ret = 1
          # If max and min occurrences are default (1) then simply iterate over the
          # particles of the <sequence>.
          if particle.min_occurs == 1 && particle.max_occurs == 1
            sub = particle.children.children
            while sub
              tmp2 = build_a_content_model(pctxt, sub)
              ret = 0 if tmp2 != 1
              sub = sub.next
            end
          else
            oldstate = pctxt.state

            if particle.max_occurs >= UNBOUNDED
              if particle.min_occurs > 1
                pctxt.state = XmlRegexp.automata_new_epsilon(am, oldstate, nil)
                oldstate = pctxt.state

                counter = XmlRegexp.automata_new_counter(am, particle.min_occurs - 1, UNBOUNDED)

                sub = particle.children.children
                while sub
                  tmp2 = build_a_content_model(pctxt, sub)
                  ret = 0 if tmp2 != 1
                  sub = sub.next
                end
                tmp = pctxt.state
                XmlRegexp.automata_new_counted_trans(am, tmp, oldstate, counter)
                pctxt.state = XmlRegexp.automata_new_counter_trans(am, tmp, nil, counter)
                XmlRegexp.automata_new_epsilon(am, oldstate, pctxt.state) if ret == 1
              else
                pctxt.state = XmlRegexp.automata_new_epsilon(am, oldstate, nil)
                oldstate = pctxt.state

                sub = particle.children.children
                while sub
                  tmp2 = build_a_content_model(pctxt, sub)
                  ret = 0 if tmp2 != 1
                  sub = sub.next
                end
                XmlRegexp.automata_new_epsilon(am, pctxt.state, oldstate)
                # epsilon needed to block previous trans from being allowed to enter back
                # from another construct
                pctxt.state = XmlRegexp.automata_new_epsilon(am, pctxt.state, nil)
                if particle.min_occurs == 0
                  XmlRegexp.automata_new_epsilon(am, oldstate, pctxt.state)
                  ret = 1
                end
              end
            elsif particle.max_occurs > 1 || particle.min_occurs > 1
              pctxt.state = XmlRegexp.automata_new_epsilon(am, oldstate, nil)
              oldstate = pctxt.state

              counter = XmlRegexp.automata_new_counter(am, particle.min_occurs - 1,
                particle.max_occurs - 1)

              sub = particle.children.children
              while sub
                tmp2 = build_a_content_model(pctxt, sub)
                ret = 0 if tmp2 != 1
                sub = sub.next
              end
              tmp = pctxt.state
              XmlRegexp.automata_new_counted_trans(am, tmp, oldstate, counter)
              pctxt.state = XmlRegexp.automata_new_counter_trans(am, tmp, nil, counter)
              if particle.min_occurs == 0 || ret == 1
                XmlRegexp.automata_new_epsilon(am, oldstate, pctxt.state)
                ret = 1
              end
            else
              sub = particle.children.children
              while sub
                tmp2 = build_a_content_model(pctxt, sub)
                ret = 0 if tmp2 != 1
                sub = sub.next
              end

              # epsilon needed to block previous trans from being allowed to enter back
              # from another construct
              pctxt.state = XmlRegexp.automata_new_epsilon(am, pctxt.state, nil)

              if particle.min_occurs == 0
                XmlRegexp.automata_new_epsilon(am, oldstate, pctxt.state)
                ret = 1
              end
            end
          end
        when XML_SCHEMA_TYPE_CHOICE
          ret = 0
          start = pctxt.state
          end_ = XmlRegexp.automata_new_state(am)

          # iterate over the subtypes and remerge the end with an epsilon transition
          if particle.max_occurs == 1
            sub = particle.children.children
            while sub
              pctxt.state = start
              tmp2 = build_a_content_model(pctxt, sub)
              ret = 1 if tmp2 == 1
              XmlRegexp.automata_new_epsilon(am, pctxt.state, end_)
              sub = sub.next
            end
          else
            max_occurs = particle.max_occurs == UNBOUNDED ? UNBOUNDED : particle.max_occurs - 1
            min_occurs = particle.min_occurs < 1 ? 0 : particle.min_occurs - 1

            # use a counter to keep track of the number of transitions which went
            # through the choice.
            counter = XmlRegexp.automata_new_counter(am, min_occurs, max_occurs)
            hop = XmlRegexp.automata_new_state(am)
            base = XmlRegexp.automata_new_state(am)

            sub = particle.children.children
            while sub
              pctxt.state = base
              tmp2 = build_a_content_model(pctxt, sub)
              ret = 1 if tmp2 == 1
              XmlRegexp.automata_new_epsilon(am, pctxt.state, hop)
              sub = sub.next
            end
            XmlRegexp.automata_new_epsilon(am, start, base)
            XmlRegexp.automata_new_counted_trans(am, hop, base, counter)
            XmlRegexp.automata_new_counter_trans(am, hop, end_, counter)
            XmlRegexp.automata_new_epsilon(am, base, end_) if ret == 1
          end
          if particle.min_occurs == 0
            XmlRegexp.automata_new_epsilon(am, start, end_)
            ret = 1
          end
          pctxt.state = end_
        when XML_SCHEMA_TYPE_ALL
          ret = 1
          sub = particle.children.children
          unless sub.nil?
            ret = 0

            start = pctxt.state
            tmp = XmlRegexp.automata_new_state(am)
            XmlRegexp.automata_new_epsilon(am, pctxt.state, tmp)
            pctxt.state = tmp
            while sub
              pctxt.state = tmp

              elem_decl = sub.children
              if elem_decl.nil?
                internal_err(pctxt, "xmlSchemaBuildAContentModel", "<element> particle has no term")
                return ret
              end
              # NOTE: The {max occurs} of all the particles in the {particles} of the group
              # must be 0 or 1; this is already ensured during the parse of <all>.
              if (elem_decl.flags & XML_SCHEMAS_ELEM_SUBST_GROUP_HEAD) != 0
                # This is an abstract group, we need to share the same counter for all
                # the element transitions derived from the group
                counter = XmlRegexp.automata_new_counter(am, sub.min_occurs, sub.max_occurs)
                build_content_model_for_subst_group(pctxt, sub, counter, pctxt.state)
              elsif sub.min_occurs == 1 && sub.max_occurs == 1
                XmlRegexp.automata_new_once_trans2(am, pctxt.state, pctxt.state,
                  elem_decl.name, elem_decl.target_namespace, 1, 1, elem_decl)
              elsif sub.min_occurs == 0 && sub.max_occurs == 1
                XmlRegexp.automata_new_count_trans2(am, pctxt.state, pctxt.state,
                  elem_decl.name, elem_decl.target_namespace, 0, 1, elem_decl)
              end
              sub = sub.next
            end
            pctxt.state = XmlRegexp.automata_new_all_trans(am, pctxt.state, nil, 0)
            if particle.min_occurs == 0
              XmlRegexp.automata_new_epsilon(am, start, pctxt.state)
              ret = 1
            end
          end
        when XML_SCHEMA_TYPE_GROUP
          # If we hit a model group definition, then this means that it was empty, thus
          # was not substituted for the containing model group. Just do nothing.
          ret = 1
        else
          internal_err2(pctxt, "xmlSchemaBuildAContentModel",
            "found unexpected term of type '%s' in content model",
            get_component_type_str(particle.children), nil)
          return ret
        end
        ret
      end

      # xmlSchemaBuildContentModel
      # Builds the content model of the complex type.
      def build_content_model(type, ctxt)
        return if type.type != XML_SCHEMA_TYPE_COMPLEX || !type.cont_model.nil? ||
          (type.content_type != XML_SCHEMA_CONTENT_ELEMENTS &&
           type.content_type != XML_SCHEMA_CONTENT_MIXED)

        ctxt.am = XmlRegexp.new_automata
        ctxt.state = XmlRegexp.automata_get_init_state(ctxt.am)
        # Build the automaton.
        build_a_content_model(ctxt, type.subtypes)
        XmlRegexp.automata_set_final_state(ctxt.am, ctxt.state)
        type.cont_model = XmlRegexp.automata_compile(ctxt.am)
        if type.cont_model.nil?
          p_custom_err(ctxt, ErrCode::SCHEMAP_INTERNAL, type, type.node,
            "Failed to compile the content model", nil)
        elsif XmlRegexp.regexp_is_determinist(type.cont_model) != 1
          p_custom_err(ctxt, ErrCode::SCHEMAP_NOT_DETERMINISTIC, type, type.node,
            "The content model is not determinist", nil)
        end
        ctxt.state = nil
        ctxt.am = nil
      end
    end
  end
end
