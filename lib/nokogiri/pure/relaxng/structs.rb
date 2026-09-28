# frozen_string_literal: true

# relaxng.c: constants and structures.
module Nokogiri
  module Pure
    module RelaxNG
      XML_RELAXNG_NS = "http://relaxng.org/ns/structure/1.0"
      XSD_DATATYPES_NS = "http://www.w3.org/2001/XMLSchema-datatypes"

      MAX_ERROR = 5
      MAX_ATTR = 20

      # xmlRelaxNGCombine
      COMBINE_UNDEFINED = 0
      COMBINE_CHOICE = 1
      COMBINE_INTERLEAVE = 2

      # xmlRelaxNGContentType
      CONTENT_ERROR = -1
      CONTENT_EMPTY = 0
      CONTENT_SIMPLE = 1
      CONTENT_COMPLEX = 2

      # xmlRelaxNGType
      NOOP = -1
      EMPTY = 0
      NOT_ALLOWED = 1
      EXCEPT = 2
      TEXT = 3
      ELEMENT = 4
      DATATYPE = 5
      PARAM = 6
      VALUE = 7
      LIST = 8
      ATTRIBUTE = 9
      DEF = 10
      REF = 11
      EXTERNALREF = 12
      PARENTREF = 13
      OPTIONAL = 14
      ZEROORMORE = 15
      ONEORMORE = 16
      CHOICE = 17
      GROUP = 18
      INTERLEAVE = 19
      START = 20

      # define dflags
      IS_NULLABLE = 1 << 0
      IS_NOT_NULLABLE = 1 << 1
      IS_INDETERMINIST = 1 << 2
      IS_MIXED = 1 << 3
      IS_TRIABLE = 1 << 4
      IS_PROCESSED = 1 << 5
      IS_COMPILABLE = 1 << 6
      IS_NOT_COMPILABLE = 1 << 7
      IS_EXTERNAL_REF = 1 << 8

      # parser flags
      IN_ATTRIBUTE = 1 << 0
      IN_ONEORMORE = 1 << 1
      IN_LIST = 1 << 2
      IN_DATAEXCEPT = 1 << 3
      IN_START = 1 << 4
      IN_OOMGROUP = 1 << 5
      IN_OOMINTERLEAVE = 1 << 6
      IN_EXTERNALREF = 1 << 7
      IN_ANYEXCEPT = 1 << 8
      IN_NSEXCEPT = 1 << 9

      # validation flags
      FLAGS_IGNORABLE = 1
      FLAGS_NEGATIVE = 2
      FLAGS_MIXED_CONTENT = 4
      FLAGS_NOERROR = 8

      # partition flags
      IS_DETERMINIST = 1
      IS_NEEDCHECK = 2

      ERROR_IS_DUP = 1

      # xmlRelaxNGValidErr
      OK = 0
      ERR_MEMORY = 1
      ERR_TYPE = 2
      ERR_TYPEVAL = 3
      ERR_DUPID = 4
      ERR_TYPECMP = 5
      ERR_NOSTATE = 6
      ERR_NODEFINE = 7
      ERR_LISTEXTRA = 8
      ERR_LISTEMPTY = 9
      ERR_INTERNODATA = 10
      ERR_INTERSEQ = 11
      ERR_INTEREXTRA = 12
      ERR_ELEMNAME = 13
      ERR_ATTRNAME = 14
      ERR_ELEMNONS = 15
      ERR_ATTRNONS = 16
      ERR_ELEMWRONGNS = 17
      ERR_ATTRWRONGNS = 18
      ERR_ELEMEXTRANS = 19
      ERR_ATTREXTRANS = 20
      ERR_ELEMNOTEMPTY = 21
      ERR_NOELEM = 22
      ERR_NOTELEM = 23
      ERR_ATTRVALID = 24
      ERR_CONTENTVALID = 25
      ERR_EXTRACONTENT = 26
      ERR_INVALIDATTR = 27
      ERR_DATAELEM = 28
      ERR_VALELEM = 29
      ERR_LISTELEM = 30
      ERR_DATATYPE = 31
      ERR_VALUE = 32
      ERR_LIST = 33
      ERR_NOGRAMMAR = 34
      ERR_EXTRADATA = 35
      ERR_LACKDATA = 36
      ERR_INTERNAL = 37
      ERR_ELEMWRONG = 38
      ERR_TEXTWRONG = 39

      # the "\1" name used by xmlRelaxNGCompareNameClasses
      INVALID_NAME = "\u0001"

      # struct _xmlRelaxNGGrammar
      class Grammar
        attr_accessor :parent, :children, :next, :start, :combine, :start_list, :defs, :refs

        def initialize
          @parent = @children = @next = @start = @start_list = @defs = @refs = nil
          @combine = COMBINE_UNDEFINED
        end
      end

      # struct _xmlRelaxNGDefine
      class Define
        attr_accessor :type, :node, :name, :ns, :value, :data, :content, :parent, :next, :attrs,
          :name_class, :next_hash, :depth, :dflags, :cont_model

        def initialize(node)
          @type = EMPTY
          @node = node
          @name = @ns = @value = @data = @content = @parent = @next = @attrs = nil
          @name_class = @next_hash = @cont_model = nil
          @depth = -1
          @dflags = 0
        end

        def inspect
          "#<RelaxNG::Define #{RelaxNG.def_name(self)} #{@name.inspect}#{@ns ? " ns=#{@ns.inspect}" : ""}>"
        end
      end

      # struct _xmlRelaxNG
      class Schema
        attr_accessor :_private, :topgrammar, :doc, :idref, :defs, :refs, :documents, :includes,
          :def_nr, :def_tab

        def initialize
          @_private = @topgrammar = @doc = @defs = @refs = @documents = @includes = @def_tab = nil
          @idref = 0
          @def_nr = 0
        end
      end

      # struct _xmlRelaxNGParserCtxt
      class ParserCtxt
        attr_accessor :user_data, :serror, :err, :schema, :grammar, :parentgrammar, :flags,
          :nb_errors, :nb_warnings, :define, :def, :nb_interleaves, :interleaves, :documents,
          :includes, :url, :document, :def_tab, :buffer, :doc, :doc_tab, :inc, :inc_tab, :idref,
          :am, :state, :crng, :freedoc

        def initialize
          @user_data = @serror = @schema = @grammar = @parentgrammar = @define = @def = nil
          @interleaves = @documents = @includes = @url = @document = @buffer = nil
          @doc = @inc = @am = @state = nil
          @err = 0
          @flags = 0
          @nb_errors = 0
          @nb_warnings = 0
          @nb_interleaves = 0
          @def_tab = []
          @doc_tab = []
          @inc_tab = []
          @idref = 0
          @crng = 0
          @freedoc = 0
        end

        def def_nr = @def_tab.size
        def doc_nr = @doc_tab.size
        def inc_nr = @inc_tab.size
      end

      # struct _xmlRelaxNGInterleaveGroup
      InterleaveGroup = Struct.new(:rule, :defs, :attrs)

      # struct _xmlRelaxNGPartition
      class Partition
        attr_accessor :nbgroups, :triage, :flags, :groups

        def initialize
          @nbgroups = 0
          @triage = nil
          @flags = 0
          @groups = nil
        end
      end

      # A C "xmlChar *" pointing into a NUL-terminated byte buffer. The list validation code
      # of relaxng.c splits values in place (blanks -> NUL) and walks/compares raw pointers,
      # which this emulates: == is pointer identity.
      class CPtr
        attr_reader :buf, :pos

        def initialize(buf, pos)
          @buf = buf
          @pos = pos
        end

        # a fresh NUL-terminated copy of +str+ (xmlStrdup)
        def self.dup(str)
          b = str.b # a fresh binary copy
          b << "\0"
          new(b, 0)
        end

        def byte(i = 0) = @buf.getbyte(@pos + i) || 0

        def set_byte(i, v)
          @buf.setbyte(@pos + i, v)
        end

        def +(other) = CPtr.new(@buf, @pos + other)

        def ==(other)
          other.is_a?(CPtr) && other.buf.equal?(@buf) && other.pos == @pos
        end
        alias_method :eql?, :==

        def hash = [@buf.object_id, @pos].hash

        # the C string at this pointer
        def str
          e = @buf.index("\0", @pos) || @buf.bytesize
          @buf.byteslice(@pos, e - @pos).force_encoding(Encoding::UTF_8)
        end

        def to_s = str

        def inspect = "#<CPtr #{str.inspect}@#{@pos}>"
      end

      # the C string behind a CPtr or String (nil stays nil)
      def self.cstr(v)
        v.is_a?(CPtr) ? v.str : v
      end

      # struct _xmlRelaxNGValidState
      class ValidState
        attr_accessor :node, :seq, :nb_attrs, :max_attrs, :nb_attr_left, :value, :endvalue, :attrs

        def initialize
          @node = @seq = @value = @endvalue = nil
          @nb_attrs = 0
          @max_attrs = 0
          @nb_attr_left = 0
          @attrs = nil
        end
      end

      # struct _xmlRelaxNGStates
      class States
        attr_accessor :nb_state, :max_state, :tab_state

        def initialize(size)
          @nb_state = 0
          @max_state = size
          @tab_state = []
        end
      end

      # struct _xmlRelaxNGValidError
      class ValidError
        attr_accessor :err, :flags, :node, :seq, :arg1, :arg2

        def initialize
          @err = 0
          @flags = 0
          @node = @seq = @arg1 = @arg2 = nil
        end
      end

      # struct _xmlRelaxNGValidCtxt
      class ValidCtxt
        attr_accessor :user_data, :serror, :nb_errors, :schema, :doc, :flags, :depth, :idref,
          :err_no, :err, :err_nr, :err_max, :err_tab, :state, :states, :free_state, :free_states,
          :elem, :elem_tab, :pstate, :pnode, :pdef, :perr

        def initialize
          @user_data = @serror = @schema = @doc = @state = @states = @free_state = nil
          @elem = @pnode = @pdef = nil
          @nb_errors = 0
          @flags = 0
          @depth = 0
          @idref = 0
          @err_no = OK
          @err = nil # index into err_tab (C: pointer into errTab) or nil
          @err_nr = 0
          @err_max = 0
          @err_tab = nil
          @free_states = nil
          @elem_tab = nil
          @pstate = 0
          @perr = 0
        end
      end

      # struct _xmlRelaxNGInclude
      class Include
        attr_accessor :next, :href, :doc, :content, :schema
      end

      # struct _xmlRelaxNGDocument
      class Document
        attr_accessor :next, :href, :doc, :content, :schema, :external_ref
      end

      # struct _xmlRelaxNGTypeLibrary: callables +have+, +check+, +comp+, +facet+, +freef+
      TypeLibrary = Struct.new(:namespace, :data, :have, :check, :comp, :facet, :freef)

      # xmlHash emulation: libxml2 randomises its hash seeds, so the scan order of these tables
      # is not reproducible anyway; insertion order is used.
      class Hash2
        def initialize
          @h = {}
        end

        # xmlHashAddEntry / xmlHashAddEntry2: -1 if the key exists (or is NULL)
        def add(name, value, name2 = nil)
          return -1 if name.nil?

          k = [name, name2]
          return -1 if @h.key?(k)

          @h[k] = value
          0
        end

        def lookup(name, name2 = nil)
          return nil if name.nil?

          @h[[name, name2]]
        end

        # xmlHashScan: callback(payload, name)
        def scan
          @h.to_a.each { |(k, v)| yield v, k[0] }
        end

        def size = @h.size
      end
    end
  end
end
