# frozen_string_literal: true

module Appsignal
  module Rack
    # @deprecated Use {InstrumentationMiddleware} instead.
    # @api private
    class GenericInstrumentation < AbstractMiddleware
      def initialize(app, options = {})
        options[:instrument_event_name] ||= "process_action.generic"
        super
      end

      def add_transaction_metadata_after(transaction, request)
        super
        transaction.set_action_if_nil("unknown")
      end
    end

    # @api private
    class GenericInstrumentationAlias < GenericInstrumentation; end
  end
end
