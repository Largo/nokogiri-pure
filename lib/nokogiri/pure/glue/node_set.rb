# frozen_string_literal: true

# Port of ext/nokogiri/xml_node_set.c and xml_namespace.c

module Nokogiri
  module XML
    class NodeSet
      def length
        __nodes.length
      end

      def push(node)
        __check_node_type(node)
        c = Nokogiri::Pure.unwrap(node)
        nodes = __nodes
        nodes << c unless nodes.any? { |n| n.equal?(c) }
        self
      end

      def delete(node)
        __check_node_type(node)
        c = Nokogiri::Pure.unwrap(node)
        nodes = __nodes
        idx = nodes.index { |n| n.equal?(c) }
        if idx
          nodes.delete_at(idx)
          return node
        end
        nil
      end

      def &(other)
        raise ArgumentError, "node_set must be a Nokogiri::XML::NodeSet" unless other.is_a?(Nokogiri::XML::NodeSet)

        other_nodes = other.__send__(:__nodes)
        lookup = other_nodes.to_h { |n| [n.object_id, true] }
        result = __nodes.select { |n| lookup[n.object_id] }
        Nokogiri::Pure.wrap_node_set(result, @document)
      end

      def include?(node)
        __check_node_type(node)
        c = Nokogiri::Pure.unwrap(node)
        __nodes.any? { |n| n.equal?(c) }
      end

      def |(other)
        raise ArgumentError, "node_set must be a Nokogiri::XML::NodeSet" unless other.is_a?(Nokogiri::XML::NodeSet)

        result = Nokogiri::Pure::XPath.node_set_merge(nil, __nodes)
        result = Nokogiri::Pure::XPath.node_set_merge(result, other.__send__(:__nodes))
        Nokogiri::Pure.wrap_node_set(result, @document)
      end

      def -(other)
        raise ArgumentError, "node_set must be a Nokogiri::XML::NodeSet" unless other.is_a?(Nokogiri::XML::NodeSet)

        result = Nokogiri::Pure::XPath.node_set_merge(nil, __nodes)
        other.__send__(:__nodes).each do |o|
          idx = result.index { |n| n.equal?(o) }
          result.delete_at(idx) if idx
        end
        Nokogiri::Pure.wrap_node_set(result, @document)
      end

      def [](*args)
        nodes = __nodes
        if args.length == 2
          beg = Nokogiri::Pure.int(args[0])
          len = Nokogiri::Pure.int(args[1])
          beg += nodes.length if beg < 0
          return __subseq(beg, len)
        end
        raise ArgumentError, "wrong number of arguments (given #{args.length}, expected 1..2)" if args.length != 1

        arg = args[0]
        return __index_at(arg) if arg.is_a?(Integer)

        if arg.is_a?(Range)
          beg, len = __range_beg_len(arg, nodes.length)
          return nil if beg.nil?

          return __subseq(beg, len)
        end
        __index_at(Nokogiri::Pure.int(arg))
      end
      alias_method :slice, :[]

      def to_a
        __nodes.map { |n| Nokogiri::Pure.wrap_node_set_result(n) }
      end

      def unlink
        nodes = __nodes
        nodes.each_with_index do |c, j|
          next if c.is_a?(Nokogiri::Pure::XmlNs)

          node = Nokogiri::Pure.wrap_node(c)
          node.unlink
          nodes[j] = Nokogiri::Pure.unwrap(node)
        end
        self
      end

      private

      def __nodes
        @__native ||= []
      end

      def initialize_copy(other)
        @__native = Nokogiri::Pure::XPath.node_set_merge(nil, other.__send__(:__nodes))
        document = other.instance_variable_get(:@document)
        unless document.nil?
          @document = document
          document.decorate(self)
        end
        self
      end

      def __check_node_type(node)
        unless node.is_a?(Nokogiri::XML::Node) || node.is_a?(Nokogiri::XML::Namespace)
          raise ArgumentError, "node must be a Nokogiri::XML::Node or Nokogiri::XML::Namespace"
        end
      end

      def __index_at(offset)
        nodes = __nodes
        return nil if offset >= nodes.length || offset < -nodes.length

        offset += nodes.length if offset < 0
        Nokogiri::Pure.wrap_node_set_result(nodes[offset])
      end

      def __subseq(beg, len)
        nodes = __nodes
        return nil if beg > nodes.length
        return nil if beg < 0 || len < 0

        len = nodes.length - beg if beg + len > nodes.length
        Nokogiri::Pure.wrap_node_set(nodes[beg, len], @document)
      end

      # rb_range_beg_len(range, &beg, &len, len, err=0)
      def __range_beg_len(range, length)
        beg = range.begin.nil? ? 0 : Nokogiri::Pure.int(range.begin)
        en = range.end.nil? ? -1 : Nokogiri::Pure.int(range.end)
        excl = range.end.nil? ? false : range.exclude_end?
        origbeg = beg
        beg += length if beg < 0
        return nil if beg < 0
        en += length if en < 0
        en += 1 unless excl
        return nil if beg > length
        en = length if en > length
        len = en - beg
        len = 0 if len < 0
        _ = origbeg
        [beg, len]
      end
    end

    class Namespace
      class << self
        undef_method :new rescue nil
        undef_method :allocate rescue nil
      end

      def prefix
        @__native.prefix&.dup
      end

      def href
        @__native.href&.dup
      end
    end
  end
end
