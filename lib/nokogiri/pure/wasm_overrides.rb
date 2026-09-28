# frozen_string_literal: true

# ruby.wasm only: replacements for upstream methods that recurse through C-implemented iterators
# (`children.each { |c| c.traverse }`). On wasm every block yielded from C re-enters the VM on the
# JS engine's native stack, so such recursion overflows it after a few dozen levels. These versions
# are iterative and otherwise behave the same (same order, same `children` calls at the same
# moments, same results).

module Nokogiri
  module XML
    class Node
      # post-order: children (recursively) first, then self
      def traverse(&block)
        stack = [[self, children.to_a, 0]]
        until stack.empty?
          frame = stack.last
          node, kids, i = frame
          if i < kids.length
            frame[2] = i + 1
            kid = kids[i]
            stack << [kid, kid.children.to_a, 0]
          else
            stack.pop
            yield(node)
          end
        end
      end
    end
  end
end
