# frozen_string_literal: true

# Port of libxslt extensions.c (extension modules, functions, elements, top-level elements),
# extra.c (node-set(), xsltDebug, xsl:document & friends registration), security.c and the
# POSIX part of xsltlocale.c.

module Nokogiri
  module Pure
    module XSLT
      # xsltExtDef
      ExtDef = Struct.new(:next, :prefix, :uri, :data)
      # xsltExtModule
      ExtModule = Struct.new(:init_func, :shutdown_func, :style_init_func, :style_shutdown_func)
      # xsltExtData
      ExtData = Struct.new(:ext_module, :ext_data)
      # xsltExtElement
      ExtElement = Struct.new(:precomp, :transform)

      # the global registries (static hash tables in extensions.c)
      EXTENSIONS_HASH = {}
      FUNCTIONS_HASH = {}
      ELEMENTS_HASH = {}
      TOP_LEVELS_HASH = {}
      EXT_MUTEX = Mutex.new

      # xsltSecurityPrefs
      SecurityPrefs = Struct.new(:read_file, :create_file, :create_dir, :read_net, :write_net)
      SECPREF_READ_FILE = 1
      SECPREF_WRITE_FILE = 2
      SECPREF_CREATE_DIRECTORY = 3
      SECPREF_READ_NETWORK = 4
      SECPREF_WRITE_NETWORK = 5

      module_function

      # ---- extensions.c ---------------------------------------------------------------------------

      # xsltRegisterExtPrefix
      def register_ext_prefix(style, prefix, uri)
        return -1 if style.nil? || uri.nil?

        defn = style.ns_defs
        while defn
          return -1 if prefix == defn.prefix

          defn = defn.next
        end
        ret = ExtDef.new(style.ns_defs, prefix, uri, nil)
        style.ns_defs = ret
        mod = EXT_MUTEX.synchronize { EXTENSIONS_HASH[uri] }
        style_get_ext_data(style, uri) if mod
        0
      end

      # xsltRegisterExtFunction
      def register_ext_function(ctxt, name, uri, function)
        return -1 if ctxt.nil? || name.nil? || uri.nil? || function.nil?

        ctxt.xpath_ctxt&.register_func_ns(name, uri, function)
        ctxt.ext_functions ||= {}
        return -1 if ctxt.ext_functions.key?([name, uri])

        ctxt.ext_functions[[name, uri]] = function
        0
      end

      # xsltRegisterExtElement
      def register_ext_element(ctxt, name, uri, function)
        return -1 if ctxt.nil? || name.nil? || uri.nil? || function.nil?

        ctxt.ext_elements ||= {}
        return -1 if ctxt.ext_elements.key?([name, uri])

        ctxt.ext_elements[[name, uri]] = function
        0
      end

      # xsltFreeCtxtExts
      def free_ctxt_exts(ctxt)
        ctxt.ext_elements = nil
        ctxt.ext_functions = nil
      end

      # xsltStyleInitializeStylesheetModule
      def style_initialize_stylesheet_module(style, uri)
        return nil if style.nil? || uri.nil?

        mod = EXT_MUTEX.synchronize { EXTENSIONS_HASH[uri] }
        return nil if mod.nil?

        style.ext_infos ||= {}
        user_data = mod.style_init_func&.call(style, uri)
        container = ExtData.new(mod, user_data)
        if style.ext_infos.key?(uri)
          transform_error(nil, style, nil, "Failed to register module '#{uri}'.\n")
          style.errors += 1
          mod.style_shutdown_func&.call(style, uri, user_data)
          return nil
        end
        style.ext_infos[uri] = container
        container
      end

      # xsltStyleGetExtData
      def style_get_ext_data(style, uri)
        return nil if style.nil? || uri.nil? || EXTENSIONS_HASH.empty?

        if style.ext_infos && (dc = style.ext_infos[uri])
          return dc.ext_data
        end
        dc = style_initialize_stylesheet_module(style, uri)
        dc&.ext_data
      end

      # xsltGetExtData
      def get_ext_data(ctxt, uri)
        return nil if ctxt.nil? || uri.nil?

        if ctxt.ext_infos.nil?
          ctxt.ext_infos = {}
          data = nil
        else
          data = ctxt.ext_infos[uri]
        end
        if data.nil?
          mod = EXT_MUTEX.synchronize { EXTENSIONS_HASH[uri] }
          return nil if mod.nil? || mod.init_func.nil?

          ext_data = mod.init_func.call(ctxt, uri)
          return nil if ext_data.nil?

          data = ExtData.new(mod, ext_data)
          ctxt.ext_infos[uri] = data
        end
        data.ext_data
      end

      # xsltInitCtxtExts
      def init_ctxt_exts(ctxt)
        return -1 if ctxt.nil?

        style = ctxt.style
        return -1 if style.nil?

        ret = 0
        while style
          style.ext_infos&.each do |uri, style_data|
            mod = style_data.ext_module
            next if mod.nil? || mod.init_func.nil?
            next if ctxt.ext_infos&.key?(uri)

            ext_data = mod.init_func.call(ctxt, uri)
            ctxt.ext_infos ||= {}
            ctxt.ext_infos[uri] = ExtData.new(mod, ext_data)
            ret += 1
          end
          style = next_import(style)
        end
        ret
      end

      # xsltShutdownCtxtExts
      def shutdown_ctxt_exts(ctxt)
        return if ctxt.nil? || ctxt.ext_infos.nil?

        ctxt.ext_infos.each do |uri, data|
          mod = data.ext_module
          mod&.shutdown_func&.call(ctxt, uri, data.ext_data)
        end
        ctxt.ext_infos = nil
      end

      # xsltShutdownExts
      def shutdown_exts(style)
        return if style.nil? || style.ext_infos.nil?

        style.ext_infos.each do |uri, data|
          mod = data.ext_module
          mod&.style_shutdown_func&.call(style, uri, data.ext_data)
        end
        style.ext_infos = nil
      end

      # xsltCheckExtPrefix (compares against the registered *prefixes*)
      def check_ext_prefix(style, uri)
        return false if style.nil? || style.ns_defs.nil?

        uri = "#default" if uri.nil?
        cur = style.ns_defs
        while cur
          return true if uri == cur.prefix

          cur = cur.next
        end
        false
      end

      # xsltCheckExtURI
      def check_ext_uri(style, uri)
        return false if style.nil? || style.ns_defs.nil? || uri.nil?

        cur = style.ns_defs
        while cur
          return true if uri == cur.uri

          cur = cur.next
        end
        false
      end

      # xsltRegisterExtModuleFull
      def register_ext_module_full(uri, init_func, shutdown_func, style_init_func, style_shutdown_func)
        return -1 if uri.nil? || init_func.nil?

        EXT_MUTEX.synchronize do
          mod = EXTENSIONS_HASH[uri]
          if mod
            return mod.init_func == init_func && mod.shutdown_func == shutdown_func ? 0 : -1
          end

          EXTENSIONS_HASH[uri] = ExtModule.new(init_func, shutdown_func, style_init_func, style_shutdown_func)
        end
        0
      end

      # xsltRegisterExtModule
      def register_ext_module(uri, init_func, shutdown_func)
        register_ext_module_full(uri, init_func, shutdown_func, nil, nil)
      end

      # xsltUnregisterExtModule
      def unregister_ext_module(uri)
        return -1 if uri.nil?

        EXT_MUTEX.synchronize { EXTENSIONS_HASH.delete(uri) } ? 0 : -1
      end

      # xsltXPathGetTransformContext
      def xpath_get_transform_context(ctxt)
        return nil if ctxt.nil? || ctxt.context.nil?

        ctxt.context.extra
      end

      # xsltRegisterExtModuleFunction
      def register_ext_module_function(name, uri, function)
        return -1 if name.nil? || uri.nil? || function.nil?

        EXT_MUTEX.synchronize { FUNCTIONS_HASH[[name, uri]] = function }
        0
      end

      # xsltExtModuleFunctionLookup
      def ext_module_function_lookup(name, uri)
        return nil if name.nil? || uri.nil?

        FUNCTIONS_HASH[[name, uri]]
      end

      # xsltUnregisterExtModuleFunction
      def unregister_ext_module_function(name, uri)
        return -1 if name.nil? || uri.nil?

        EXT_MUTEX.synchronize { FUNCTIONS_HASH.delete([name, uri]) } ? 0 : -1
      end

      # xsltNewElemPreComp
      def new_elem_pre_comp(style, inst, function)
        cur = ElemPreComp.new(FUNC_EXTENSION)
        init_elem_pre_comp(cur, style, inst, function, nil)
        cur
      end

      # xsltInitElemPreComp
      def init_elem_pre_comp(comp, style, inst, function, free_func)
        comp.type = FUNC_EXTENSION
        comp.func = function
        comp.inst = inst
        comp.free = free_func
        comp.next = style.pre_comps
        style.pre_comps = comp
      end

      # xsltPreComputeExtModuleElement
      def pre_compute_ext_module_element(style, inst)
        return nil if style.nil? || inst.nil? || inst.type != ELEMENT_NODE || inst.ns.nil?

        ext = EXT_MUTEX.synchronize { ELEMENTS_HASH[[inst.name, inst.ns.href]] }
        return nil if ext.nil?

        comp = ext.precomp&.call(style, inst, ext.transform)
        comp ||= new_elem_pre_comp(style, inst, ext.transform)
        comp
      end

      # xsltRegisterExtModuleElement
      def register_ext_module_element(name, uri, precomp, transform)
        return -1 if name.nil? || uri.nil? || transform.nil?

        EXT_MUTEX.synchronize { ELEMENTS_HASH[[name, uri]] = ExtElement.new(precomp, transform) }
        0
      end

      # xsltExtElementLookup
      def ext_element_lookup(ctxt, name, uri)
        return nil if name.nil? || uri.nil?

        if ctxt&.ext_elements
          ret = ctxt.ext_elements[[name, uri]]
          return ret if ret
        end
        ext_module_element_lookup(name, uri)
      end

      # xsltExtModuleElementLookup
      def ext_module_element_lookup(name, uri)
        return nil if name.nil? || uri.nil?

        ELEMENTS_HASH[[name, uri]]&.transform
      end

      # xsltExtModuleElementPreComputeLookup
      def ext_module_element_pre_compute_lookup(name, uri)
        return nil if name.nil? || uri.nil?

        ELEMENTS_HASH[[name, uri]]&.precomp
      end

      # xsltUnregisterExtModuleElement
      def unregister_ext_module_element(name, uri)
        EXT_MUTEX.synchronize { ELEMENTS_HASH.delete([name, uri]) } ? 0 : -1
      end

      # xsltRegisterExtModuleTopLevel
      def register_ext_module_top_level(name, uri, function)
        return -1 if name.nil? || uri.nil? || function.nil?

        EXT_MUTEX.synchronize { TOP_LEVELS_HASH[[name, uri]] = function }
        0
      end

      # xsltExtModuleTopLevelLookup
      def ext_module_top_level_lookup(name, uri)
        return nil if name.nil? || uri.nil?

        TOP_LEVELS_HASH[[name, uri]]
      end

      # xsltUnregisterExtModuleTopLevel
      def unregister_ext_module_top_level(name, uri)
        EXT_MUTEX.synchronize { TOP_LEVELS_HASH.delete([name, uri]) } ? 0 : -1
      end

      # xsltGetExtInfo
      def get_ext_info(style, uri)
        return nil if style.nil? || style.ext_infos.nil?

        data = style.ext_infos[uri]
        data&.ext_data
      end

      # ---- extra.c -------------------------------------------------------------------------------

      # xsltDebug
      def debug(ctxt, _node = nil, _inst = nil, _comp = nil)
        generic_error("Templates:\n")
        i = 0
        j = ctxt.templ_tab.length - 1
        while i < 15 && j >= 0
          t = ctxt.templ_tab[j]
          generic_error("##{i} ")
          generic_error("name #{t.name} ") if t.name
          generic_error("name #{t.match} ") if t.match
          generic_error("name #{t.mode} ") if t.mode
          generic_error("\n")
          i += 1
          j -= 1
        end
        generic_error("Variables:\n")
        i = 0
        j = ctxt.vars_tab.length - 1
        while i < 15 && j >= 0
          cur = ctxt.vars_tab[j]
          if cur
            generic_error("##{i}\n")
            while cur
              if cur.comp.nil?
                generic_error("corrupted !!!\n")
              elsif cur.comp.type == FUNC_PARAM
                generic_error("param ")
              elsif cur.comp.type == FUNC_VARIABLE
                generic_error("var ")
              end
              if cur.name
                generic_error("#{cur.name} ")
              else
                generic_error("noname !!!!")
              end
              generic_error("NULL !!!!") if cur.value.nil?
              generic_error("\n")
              cur = cur.next
            end
          end
          i += 1
          j -= 1
        end
      end

      # xsltFunctionNodeSet
      def function_node_set(ctxt, nargs)
        if nargs != 1
          transform_error(xpath_get_transform_context(ctxt), nil, nil, "node-set() : expects one result-tree arg\n")
          ctxt.error = XPath::INVALID_ARITY
          return
        end
        v = ctxt.value
        if v.nil? || !v.is_a?(Array)
          transform_error(xpath_get_transform_context(ctxt), nil, nil, "node-set() invalid arg expecting a result tree\n")
          ctxt.error = XPath::INVALID_TYPE
          return
        end
        if v.is_a?(XPath::ValueTree)
          ctxt.value_pop
          ctxt.value_push(Array.new(v))
        end
      end

      # xsltRegisterAllExtras
      def register_all_extras
        ns_fn = ->(ctxt, nargs) { XSLT.function_node_set(ctxt, nargs) }
        register_ext_module_function("node-set", LIBXSLT_NAMESPACE, ns_fn)
        register_ext_module_function("node-set", SAXON_NAMESPACE, ns_fn)
        register_ext_module_function("node-set", XT_NAMESPACE, ns_fn)
        register_ext_module_element("debug", LIBXSLT_NAMESPACE, nil, instr_func(:debug))
        doc_comp = ->(style, inst, fn) { XSLT.document_comp(style, inst, fn) }
        doc_elem = instr_func(:document_elem)
        register_ext_module_element("output", SAXON_NAMESPACE, doc_comp, doc_elem)
        register_ext_module_element("write", XALAN_NAMESPACE, doc_comp, doc_elem)
        register_ext_module_element("document", XT_NAMESPACE, doc_comp, doc_elem)
        register_ext_module_element("document", NAMESPACE, doc_comp, doc_elem)
      end

      # ---- security.c --------------------------------------------------------------------------------

      def new_security_prefs
        SecurityPrefs.new
      end

      def set_security_prefs(sec, option, func)
        return -1 if sec.nil?

        case option
        when SECPREF_READ_FILE then sec.read_file = func
        when SECPREF_WRITE_FILE then sec.create_file = func
        when SECPREF_CREATE_DIRECTORY then sec.create_dir = func
        when SECPREF_READ_NETWORK then sec.read_net = func
        when SECPREF_WRITE_NETWORK then sec.write_net = func
        else return -1
        end
        0
      end

      def set_default_security_prefs(sec)
        @default_security_prefs = sec
      end

      def default_security_prefs
        @default_security_prefs
      end

      # xsltCheckWrite
      def check_write(sec, ctxt, url)
        return 1 if sec.nil?

        m = %r{\A([A-Za-z][A-Za-z0-9+.-]*):}.match(url)
        if m.nil? || m[1] == "file"
          path = url.sub(%r{\Afile://(localhost)?}, "")
          if sec.create_file && sec.create_file.call(sec, ctxt, path) == 0
            transform_error(ctxt, nil, nil, "File write for #{path} refused\n")
            return 0
          end
        elsif sec.write_net && sec.write_net.call(sec, ctxt, url) == 0
          transform_error(ctxt, nil, nil, "File write for #{url} refused\n")
          return 0
        end
        1
      end

      # xsltCheckRead
      def check_read(sec, ctxt, url)
        return 1 if sec.nil?

        unless url.include?("://")
          if sec.read_file && sec.read_file.call(sec, ctxt, url) == 0
            transform_error(ctxt, nil, nil, "Local file read for #{url} refused\n")
            return 0
          end
          return 1
        end
        m = %r{\A([A-Za-z][A-Za-z0-9+.-]*):}.match(url)
        if m.nil? || m[1] == "file"
          if sec.read_file && sec.read_file.call(sec, ctxt, url.sub(%r{\Afile://(localhost)?}, "")) == 0
            transform_error(ctxt, nil, nil, "Local file read for #{url} refused\n")
            return 0
          end
        elsif sec.read_net && sec.read_net.call(sec, ctxt, url) == 0
          transform_error(ctxt, nil, nil, "Network file read for #{url} refused\n")
          return 0
        end
        1
      end

      # ---- xsltlocale.c (POSIX) --------------------------------------------------------------------

      # xsltNewLocale: returns a locale token or nil. Only the locales that the reference system
      # provides with a non-C collation (English) are emulated; others collate like strcmp.
      def new_locale(lang, _lower_first)
        return nil if lang.nil?

        m = /\A([A-Za-z]{1,8})(?:-([A-Za-z]{1,8}))?\z/.match(lang)
        return nil if m.nil?

        m[1].casecmp?("en") ? :en : nil
      end

      # xsltStrxfrm: a collation key emulating glibc's ISO 14651 based en_US collation
      def strxfrm(locale, string)
        return string.b if locale != :en

        l1 = []
        l2 = []
        l3 = []
        l4 = []
        string.each_char do |ch|
          base = ch.unicode_normalize(:nfd)
          first = base[0]
          marks = base[1..].to_s
          if first.match?(/[[:alnum:]]/)
            down = first.downcase
            w = if down.match?(/[0-9]/)
              0x100 + down.ord
            elsif down.match?(/[a-z]/)
              0x200 + down.ord
            else
              0x1000 + down.ord
            end
            l1 << w
            l2 << (marks.empty? ? 1 : 2 + marks.ord)
            l3 << (first == down ? 1 : 2)
            l4 << 0xFFFFF
          else
            l4 << (1 + ch.ord)
          end
        end
        key = +"".b
        [l1, l2, l3, l4].each do |lv|
          lv.each { |w| key << ((w / 62_500) + 2).chr << (((w / 250) % 250) + 2).chr << ((w % 250) + 2).chr }
          key << "\x01"
        end
        key
      end
    end
  end
end
