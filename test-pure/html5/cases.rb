# frozen_string_literal: true

# Collects HTML5 parser test inputs from html5lib-tests (tree-construction data + tokenizer inputs).
require "json"

module Html5Cases
  ROOT = "/root/workspace/nokogiri-upstream/test/html5lib-tests"

  module_function

  def tree_construction
    cases = []
    Dir[File.join(ROOT, "tree-construction", "*.dat")].sort.each do |path|
      base = File.basename(path, ".dat")
      File.open(path, "r", encoding: "UTF-8") do |f|
        idx = 0
        f.each("\n\n#data\n") do |test_data|
          test_data = test_data[6..] if test_data.start_with?("#data\n")
          test_data = test_data[0..-9] if test_data.end_with?("\n\n#data\n")
          index = /(?:^#errors\n|\n#errors\n)/ =~ test_data
          next if index.nil?

          data = test_data[0...index]
          rest = test_data[index..]
          context = rest[/^#document-fragment\n(.*)$/, 1]
          script = if rest.include?("\n#script-on\n") then [true]
          elsif rest.include?("\n#script-off\n") then [false]
          else [false, true]
          end
          script.each do |s|
            cases << { id: "#{base}:#{idx}:#{s ? "on" : "off"}", data: data, context: context&.split(" ", 2)&.join(":"), script: s }
            if context
              cases << { id: "#{base}:#{idx}:#{s ? "on" : "off"}:node", data: data, context: context.split(" ", 2), script: s, node: true }
            end
          end
          idx += 1
        end
      end
    end
    cases
  end

  def tokenizer
    cases = []
    Dir[File.join(ROOT, "tokenizer", "*.test")].sort.each do |path|
      base = File.basename(path, ".test")
      json = JSON.parse(File.read(path))
      (json["tests"] || []).each_with_index do |t, i|
        input = t["input"]
        if t["doubleEscaped"]
          input = input.gsub(/\\u([0-9a-fA-F]{4})/) { [$1.hex].pack("U") rescue "�" }
          next unless input.valid_encoding?
        end
        cases << { id: "tok-#{base}:#{i}", data: input, context: nil, script: false }
        cases << { id: "tok-#{base}:#{i}:frag", data: input, context: "div", script: false }
      end
    end
    cases
  end

  def all
    tree_construction + tokenizer
  end
end
