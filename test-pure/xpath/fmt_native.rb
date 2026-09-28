gem "nokogiri", "1.19.4"
require "nokogiri"
d = Nokogiri::XML("<a/>")
nums = [1.0, 0.5, 1e10, 123456789.5, 1e-5, 1.5e-6, -0.25, 3.14159265358979, 1e21, 0.1+0.2, 1/3.0, -1e100, 2**31+0.5, 1e9+0.5, 100.0/7, 2.0**40, -0.0, 12345.678901234567, 1e-300, 5e-324, 1.7976931348623157e308, 0.000123, 999999999.9999999]
strs = ["1", "1.5", "-2", ".5", "5.", "abc", "1e3", "1.2E-2", "+1", " 7 ", "-.5", ".", "", "0.1234567890123456789012345", "12345678901234567890", "1e-400", "00012", "1.", " \t\n12\r"]
nums.each { |f| ctx = Nokogiri::XML::XPathContext.new(d); ctx.register_variable("v", f.to_s) ; puts "#{f.inspect} #{d.xpath("string(number($v))", nil, v: f.inspect)}" }
strs.each { |s| puts "#{s.inspect} #{d.xpath("number($v)", nil, v: s).inspect}" }
