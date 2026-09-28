# Unmodified gems that depend on nokogiri (loofah, rails-html-sanitizer), running on nokogiri-pure.
# Expected output (gems_demo.expected) was produced with the native nokogiri gem.
require "loofah"
require "rails-html-sanitizer"
html = %(<p onclick="evil()">Hello <b>world</b><script>alert(1)</script> <a href="javascript:x">x</a> <img src=x onerror=y></p>)
puts Loofah.fragment(html).scrub!(:prune).to_s
puts Loofah.fragment(html).scrub!(:strip).to_s
puts Rails::HTML5::SafeListSanitizer.new.sanitize(html)
puts Rails::HTML4::FullSanitizer.new.sanitize(html)
puts Rails::HTML5::LinkSanitizer.new.sanitize(%(<a href="/x">link</a> text))
