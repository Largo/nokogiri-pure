# frozen_string_literal: true

# Port of ext/nokogiri/test_global_handlers.c

module Nokogiri
  module Test
    class << self
      # installs a "foreign" global structured error handler; the test suite asserts that Nokogiri
      # never lets errors leak into it
      def __foreign_error_handler(&block)
        raise LocalJumpError, "no block given" unless block

        Nokogiri::Pure::Errors.handler = ->(_err) { block.call }
        nil
      end
    end
  end
end
