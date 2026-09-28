# frozen_string_literal: true

# DTD validation (valid.c xmlValidate*). Filled in after the parser.

module Nokogiri
  module Pure
    module Valid
      module_function

      def validate_root(_vctxt, _doc) = 1
      def validate_attribute_decl(_vctxt, _doc, _attr) = 1
      def validate_element_decl(_vctxt, _doc, _elem) = 1
      def validate_notation_decl(_vctxt, _doc, _nota) = 1
      def validate_document_final(_vctxt, _doc) = 1
      def validate_dtd_final(_vctxt, _doc) = 1
      def validate_one_element(_vctxt, _doc, _elem) = 1
      def validate_one_attribute(_vctxt, _doc, _elem, _attr, _value) = 1
      def validate_one_namespace(_vctxt, _doc, _elem, _prefix, _ns, _value) = 1

      def validate_dtd(_doc, _dtd)
        1
      end
    end
  end
end
