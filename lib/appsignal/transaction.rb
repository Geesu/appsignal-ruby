# frozen_string_literal: true

require "json"

module Appsignal
  class Transaction
    HTTP_REQUEST   = "http_request"
    BACKGROUND_JOB = "background_job"
    # @api private
    ACTION_CABLE   = "action_cable"
    # @api private
    FRONTEND       = "frontend"
    # @api private
    BLANK          = ""
    # @api private
    ALLOWED_TAG_KEY_TYPES = [Symbol, String].freeze
    # @api private
    ALLOWED_TAG_VALUE_TYPES = [Symbol, String, Integer, TrueClass, FalseClass].freeze
    # @api private
    BREADCRUMB_LIMIT = 20
    # @api private
    ERROR_CAUSES_LIMIT = 10

    class << self
      # Create a new transaction and set it as the currently active
      # transaction.
      def create(id, namespace, request, options = {})
        # Allow middleware to force a new transaction
        Thread.current[:appsignal_transaction] = nil if options.include?(:force) && options[:force]

        # Check if we already have a running transaction
        if Thread.current[:appsignal_transaction].nil?
          # If not, start a new transaction
          Thread.current[:appsignal_transaction] =
            Appsignal::Transaction.new(id, namespace, request, options)
        else
          # Otherwise, log the issue about trying to start another transaction
          Appsignal.internal_logger.warn(
            "Trying to start new transaction with id " \
              "'#{id}', but a transaction with id '#{current.transaction_id}' " \
              "is already running. Using transaction '#{current.transaction_id}'."
          )

          # And return the current transaction instead
          current
        end
      end

      # Returns currently active transaction or a {NilTransaction} if none is
      # active.
      #
      # @see .current?
      # @return [Boolean]
      def current
        Thread.current[:appsignal_transaction] || NilTransaction.new
      end

      # Returns if any transaction is currently active or not. A
      # {NilTransaction} is not considered an active transaction.
      #
      # @see .current
      # @return [Boolean]
      def current?
        current && !current.nil_transaction?
      end

      # Complete the currently active transaction and unset it as the active
      # transaction.
      def complete_current!
        current.complete
      rescue => e
        Appsignal.internal_logger.error(
          "Failed to complete transaction ##{current.transaction_id}. #{e.message}"
        )
      ensure
        clear_current_transaction!
      end

      # Remove current transaction from current Thread.
      # @api private
      def clear_current_transaction!
        Thread.current[:appsignal_transaction] = nil
      end
    end

    # @api private
    attr_reader :ext, :transaction_id, :action, :namespace, :request, :paused, :tags, :options,
      :breadcrumbs, :custom_data

    def initialize(transaction_id, namespace, request, options = {})
      @transaction_id = transaction_id
      @action = nil
      @namespace = namespace
      @request = request
      @paused = false
      @discarded = false
      @tags = {}
      @custom_data = nil
      @breadcrumbs = []
      @store = Hash.new({})
      @options = options
      @options[:params_method] ||= :params
      @params = nil
      @session_data = nil
      @headers = nil

      @ext = Appsignal::Extension.start_transaction(
        @transaction_id,
        @namespace,
        0
      ) || Appsignal::Extension::MockTransaction.new
    end

    def nil_transaction?
      false
    end

    def complete
      if discarded?
        Appsignal.internal_logger.debug "Skipping transaction '#{transaction_id}' " \
          "because it was manually discarded."
        return
      end
      _sample_data if @ext.finish(0)
      @ext.complete
    end

    def pause!
      @paused = true
    end

    def resume!
      @paused = false
    end

    def paused?
      @paused == true
    end

    # @api private
    def discard!
      @discarded = true
    end

    # @api private
    def restore!
      @discarded = false
    end

    # @api private
    def discarded?
      @discarded == true
    end

    # @api private
    def store(key)
      @store[key]
    end

    def params
      parameters = @params || request_params

      if parameters.respond_to? :call
        parameters.call
      else
        parameters
      end
    rescue => e
      Appsignal.internal_logger.error("Exception while fetching params: #{e.class}: #{e}")
      nil
    end

    # Set parameters on the transaction.
    #
    # When no parameters are set this way, the transaction will look for
    # parameters on the {#request} environment.
    #
    # The parameters set using {#set_params} are leading over those extracted
    # from a request's environment.
    #
    # When both the `given_params` and a block is given to this method, the
    # `given_params` argument is leading and the block will _not_ be called.
    #
    # @since 3.9.1
    # @param given_params [Hash] The parameters to set on the transaction.
    # @yield This block is called when the transaction is sampled. The block's
    #   return value will become the new parameters.
    # @return [void]
    # @see Helpers::Instrumentation#set_params
    def set_params(given_params = nil, &block)
      @params = block if block
      @params = given_params if given_params
    end

    # @deprecated Use {#set_params} or {#set_params_if_nil} instead.
    def params=(given_params)
      Appsignal::Utils::StdoutAndLoggerMessage.warning(
        "Transaction#params= is deprecated." \
          "Use Transaction#set_params or #set_params_if_nil instead."
      )
      set_params(given_params)
    end

    # Set parameters on the transaction if not already set
    #
    # When no parameters are set this way, the transaction will look for
    # parameters on the {#request} environment.
    #
    # @since 3.9.1
    # @param given_params [Hash] The parameters to set on the transaction if none are already set.
    # @yield This block is called when the transaction is sampled. The block's
    #   return value will become the new parameters.
    # @return [void]
    #
    # @see #set_params
    # @see Helpers::Instrumentation#set_params_if_nil
    def set_params_if_nil(given_params = nil, &block)
      set_params(given_params, &block) unless @params
    end

    # Set tags on the transaction.
    #
    # When this method is called multiple times, it will merge the tags.
    #
    # @param given_tags [Hash] Collection of tags.
    # @option given_tags [String, Symbol, Integer] :any
    #   The name of the tag as a Symbol.
    # @option given_tags [String, Symbol, Integer] "any"
    #   The name of the tag as a String.
    # @return [void]
    #
    # @see Helpers::Instrumentation#tag_request
    # @see https://docs.appsignal.com/ruby/instrumentation/tagging.html
    #   Tagging guide
    def set_tags(given_tags = {})
      @tags.merge!(given_tags)
    end

    # Set session data on the transaction.
    #
    # When both the `given_session_data` and a block is given to this method,
    # the `given_session_data` argument is leading and the block will _not_ be
    # called.
    #
    # @param given_session_data [Hash] A hash containing session data.
    # @yield This block is called when the transaction is sampled. The block's
    #   return value will become the new session data.
    # @return [void]
    #
    # @since 3.10.1
    # @see Helpers::Instrumentation#set_session_data
    # @see https://docs.appsignal.com/guides/custom-data/sample-data.html
    #   Sample data guide
    def set_session_data(given_session_data = nil, &block)
      @session_data = block if block
      @session_data = given_session_data if given_session_data
    end

    # Set session data on the transaction if not already set.
    #
    # When both the `given_session_data` and a block is given to this method,
    # the `given_session_data` argument is leading and the block will _not_ be
    # called.
    #
    # @param given_session_data [Hash] A hash containing session data.
    # @yield This block is called when the transaction is sampled. The block's
    #   return value will become the new session data.
    # @return [void]
    #
    # @since 3.10.1
    # @see #set_session_data
    # @see https://docs.appsignal.com/guides/custom-data/sample-data.html
    #   Sample data guide
    def set_session_data_if_nil(given_session_data = nil, &block)
      set_session_data(given_session_data, &block) unless @session_data
    end

    # Set headers on the transaction.
    #
    # When both the `given_headers` and a block is given to this method,
    # the `given_headers` argument is leading and the block will _not_ be
    # called.
    #
    # @param given_headers [Hash] A hash containing headers.
    # @yield This block is called when the transaction is sampled. The block's
    #   return value will become the new headers.
    # @return [void]
    #
    # @since 3.10.1
    # @see Helpers::Instrumentation#set_headers
    # @see https://docs.appsignal.com/guides/custom-data/sample-data.html
    #   Sample data guide
    def set_headers(given_headers = nil, &block)
      @headers = block if block
      @headers = given_headers if given_headers
    end

    # Set headers on the transaction if not already set.
    #
    # When both the `given_headers` and a block is given to this method,
    # the `given_headers` argument is leading and the block will _not_ be
    # called.
    #
    # @param given_headers [Hash] A hash containing headers.
    # @yield This block is called when the transaction is sampled. The block's
    #   return value will become the new headers.
    # @return [void]
    #
    # @since 3.10.1
    # @see #set_headers
    # @see https://docs.appsignal.com/guides/custom-data/sample-data.html
    #   Sample data guide
    def set_headers_if_nil(given_headers = nil, &block)
      set_headers(given_headers, &block) unless @headers
    end

    # Set custom data on the transaction.
    #
    # When this method is called multiple times, it will overwrite the
    # previously set value.
    #
    # @since 3.10.0
    # @see Appsignal.set_custom_data
    # @see https://docs.appsignal.com/guides/custom-data/sample-data.html
    #   Sample data guide
    # @param data [Hash/Array]
    # @return [void]
    def set_custom_data(data)
      case data
      when Array, Hash
        @custom_data = data
      else
        Appsignal.internal_logger
          .error("set_custom_data: Unsupported data type #{data.class} received.")
      end
    end

    # Add breadcrumbs to the transaction.
    #
    # @param category [String] category of breadcrumb
    #   e.g. "UI", "Network", "Navigation", "Console".
    # @param action [String] name of breadcrumb
    #   e.g "The user clicked a button", "HTTP 500 from http://blablabla.com"
    # @option message [String]  optional message in string format
    # @option metadata [Hash<String,String>]  key/value metadata in <string, string> format
    # @option time [Time] time of breadcrumb, should respond to `.to_i` defaults to `Time.now.utc`
    # @return [void]
    #
    # @see Appsignal.add_breadcrumb
    # @see https://docs.appsignal.com/ruby/instrumentation/breadcrumbs.html
    #   Breadcrumb reference
    def add_breadcrumb(category, action, message = "", metadata = {}, time = Time.now.utc)
      unless metadata.is_a? Hash
        Appsignal.internal_logger.error "add_breadcrumb: Cannot add breadcrumb. " \
          "The given metadata argument is not a Hash."
        return
      end

      @breadcrumbs.push(
        :time => time.to_i,
        :category => category,
        :action => action,
        :message => message,
        :metadata => metadata
      )
      @breadcrumbs = @breadcrumbs.last(BREADCRUMB_LIMIT)
    end

    # Set an action name for the transaction.
    #
    # An action name is used to identify the location of a certain sample;
    # error and performance issues.
    #
    # @param action [String] the action name to set.
    # @return [void]
    # @see Appsignal.set_action
    # @see #set_action_if_nil
    # @since 2.2.0
    def set_action(action)
      return unless action

      @action = action
      @ext.set_action(action)
    end

    # Set an action name only if there is no current action set.
    #
    # Commonly used by AppSignal integrations so that they don't override
    # custom action names.
    #
    # @example
    #   Appsignal.set_action("foo")
    #   Appsignal.set_action_if_nil("bar")
    #   # Transaction action will be "foo"
    #
    # @param action [String]
    # @return [void]
    # @see #set_action
    # @since 2.2.0
    def set_action_if_nil(action)
      return if @action

      set_action(action)
    end

    # Set the namespace for this transaction.
    #
    # Useful to split up parts of an application into certain namespaces. For
    # example: http requests, background jobs and administration panel
    # controllers.
    #
    # Note: The "http_request" namespace gets transformed on AppSignal.com to
    # "Web" and "background_job" gets transformed to "Background".
    #
    # @example
    #   transaction.set_namespace("background")
    #
    # @param namespace [String] namespace name to use for this transaction.
    # @return [void]
    # @since 2.2.0
    def set_namespace(namespace)
      return unless namespace

      @namespace = namespace
      @ext.set_namespace(namespace)
    end

    # @api private
    def set_http_or_background_action(from = request.params)
      return unless from

      group_and_action = [
        from[:controller] || from[:class],
        from[:action] || from[:method]
      ]
      set_action_if_nil(group_and_action.compact.join("#"))
    end

    # Set queue start time for transaction.
    #
    # @param start [Integer] Queue start time in milliseconds.
    # @raise [RangeError] When the queue start time value is too big, this
    #   method raises a RangeError.
    # @raise [TypeError] Raises a TypeError when the given `start` argument is
    #   not an Integer.
    # @return [void]
    def set_queue_start(start)
      return unless start

      @ext.set_queue_start(start)
    rescue RangeError
      Appsignal.internal_logger.warn("Queue start value #{start} is too big")
    end

    # Set the queue time based on the HTTP header or `:queue_start` env key
    # value.
    #
    # This method will first try to read the queue time from the HTTP headers
    # `X-Request-Start` or `X-Queue-Start`. Which are parsed by Rack as
    # `HTTP_X_QUEUE_START` and `HTTP_X_REQUEST_START`.
    # The header value is parsed by AppSignal as either milliseconds or
    # microseconds.
    #
    # If no headers are found, or the value could not be parsed, it falls back
    # on the `:queue_start` env key on this Transaction's {request} environment
    # (called like `request.env[:queue_start]`). This value is parsed by
    # AppSignal as seconds.
    #
    # @see https://docs.appsignal.com/ruby/instrumentation/request-queue-time.html
    # @deprecated Use {#set_queue_start} instead.
    # @return [void]
    def set_http_or_background_queue_start
      Appsignal::Utils::StdoutAndLoggerMessage.warning \
        "The Appsignal::Transaction#set_http_or_background_queue_start " \
          "method has been deprecated. " \
          "Please use the Appsignal::Transaction#set_queue_start method instead."

      start = http_queue_start || background_queue_start
      return unless start

      set_queue_start(start)
    end

    def set_metadata(key, value)
      return unless key && value
      return if Appsignal.config[:filter_metadata].include?(key.to_s)

      @ext.set_metadata(key, value)
    end

    # @deprecated Use one of the set_tags, set_params, set_session_data,
    #   set_params or set_custom_data helpers instead.
    # @api private
    def set_sample_data(key, data)
      Appsignal::Utils::StdoutAndLoggerMessage.warning(
        "Appsignal::Transaction#set_sample_data is deprecated. " \
          "Please use one of the instrumentation helpers: set_tags, " \
          "set_params, set_session_data, set_params or set_custom_data."
      )
      _set_sample_data(key, data)
    end

    # @deprecated No replacement.
    # @api private
    def sample_data
      Appsignal::Utils::StdoutAndLoggerMessage.warning(
        "Appsignal::Transaction#sample_data is deprecated. " \
          "Please remove any calls to this method."
      )
      _sample_data
    end

    # @see Appsignal::Helpers::Instrumentation#set_error
    def set_error(error)
      unless error.is_a?(Exception)
        Appsignal.internal_logger.error "Appsignal::Transaction#set_error: Cannot set error. " \
          "The given value is not an exception: #{error.inspect}"
        return
      end
      return unless error
      return unless Appsignal.active?

      backtrace = cleaned_backtrace(error.backtrace)
      @ext.set_error(
        error.class.name,
        cleaned_error_message(error),
        backtrace ? Appsignal::Utils::Data.generate(backtrace) : Appsignal::Extension.data_array_new
      )

      root_cause_missing = false

      causes = []
      while error
        error = error.cause

        break unless error

        if causes.length >= ERROR_CAUSES_LIMIT
          Appsignal.internal_logger.debug "Appsignal::Transaction#set_error: Error has more " \
            "than #{ERROR_CAUSES_LIMIT} error causes. Only the first #{ERROR_CAUSES_LIMIT} " \
            "will be reported."
          root_cause_missing = true
          break
        end

        causes << error
      end

      return if causes.empty?

      causes_sample_data = causes.map do |e|
        {
          :name => e.class.name,
          :message => cleaned_error_message(e)
        }
      end

      causes_sample_data.last[:is_root_cause] = false if root_cause_missing

      _set_sample_data(
        "error_causes",
        causes_sample_data
      )
    end
    alias_method :add_exception, :set_error

    def start_event
      return if paused?

      @ext.start_event(0)
    end

    def finish_event(name, title, body, body_format = Appsignal::EventFormatter::DEFAULT)
      return if paused?

      @ext.finish_event(
        name,
        title || BLANK,
        body || BLANK,
        body_format || Appsignal::EventFormatter::DEFAULT,
        0
      )
    end

    def record_event(name, title, body, duration, body_format = Appsignal::EventFormatter::DEFAULT)
      return if paused?

      @ext.record_event(
        name,
        title || BLANK,
        body || BLANK,
        body_format || Appsignal::EventFormatter::DEFAULT,
        duration,
        0
      )
    end

    def instrument(name, title = nil, body = nil, body_format = Appsignal::EventFormatter::DEFAULT)
      start_event
      yield if block_given?
    ensure
      finish_event(name, title, body, body_format)
    end

    # @api private
    def to_h
      JSON.parse(@ext.to_json)
    end
    alias_method :to_hash, :to_h

    # @api private
    class GenericRequest
      attr_reader :env

      def initialize(env)
        @env = env
      end

      def params
        env[:params]
      end
    end

    private

    # @api private
    def _set_sample_data(key, data)
      return unless key && data

      if !data.is_a?(Array) && !data.is_a?(Hash)
        Appsignal.internal_logger.error(
          "Invalid sample data for '#{key}'. Value is not an Array or Hash: '#{data.inspect}'"
        )
        return
      end

      @ext.set_sample_data(
        key.to_s,
        Appsignal::Utils::Data.generate(data)
      )
    rescue RuntimeError => e
      begin
        inspected_data = data.inspect
        Appsignal.internal_logger.error(
          "Error generating data (#{e.class}: #{e.message}) for '#{inspected_data}'"
        )
      rescue => e
        Appsignal.internal_logger.error(
          "Error generating data (#{e.class}: #{e.message}). Can't inspect data."
        )
      end
    end

    # @api private
    def _sample_data
      {
        :params => sanitized_params,
        :environment => sanitized_environment,
        :session_data => sanitized_session_data,
        :metadata => sanitized_metadata,
        :tags => sanitized_tags,
        :breadcrumbs => breadcrumbs,
        :custom_data => custom_data
      }.each do |key, data|
        _set_sample_data(key, data)
      end
    end

    # Returns calculated background queue start time in milliseconds, based on
    # environment values.
    #
    # @return [nil] if no {#environment} is present.
    # @return [nil] if there is no `:queue_start` in the {#environment}.
    # @return [Integer] `:queue_start` time (in seconds) converted to milliseconds
    def background_queue_start
      env = environment
      return unless env

      queue_start = env[:queue_start]
      return unless queue_start

      (queue_start.to_f * 1000.0).to_i # Convert seconds to milliseconds
    end

    # Returns HTTP queue start time in milliseconds.
    #
    # @return [nil] if no queue start time is found.
    # @return [nil] if begin time is too low to be plausible.
    # @return [Integer] queue start in milliseconds.
    def http_queue_start
      env = environment
      Appsignal::Rack::Utils.queue_start_from(env)
    end

    def sanitized_params
      return unless Appsignal.config[:send_params]

      filter_keys = Appsignal.config[:filter_parameters] || []
      Appsignal::Utils::HashSanitizer.sanitize params, filter_keys
    end

    def request_params
      return unless request.respond_to?(options[:params_method])

      begin
        request.send options[:params_method]
      rescue => e
        Appsignal.internal_logger.warn "Exception while getting params: #{e}"
        nil
      end
    end

    def session_data
      if @session_data
        if @session_data.respond_to? :call
          @session_data.call
        else
          @session_data
        end
      elsif request.respond_to?(:session)
        request.session
      end
    rescue => e
      Appsignal.internal_logger.error \
        "Exception while fetching session data: #{e.class}: #{e}"
      nil
    end

    # Returns sanitized session data.
    #
    # The session data is sanitized by the {Appsignal::Utils::HashSanitizer}.
    #
    # @return [nil] if `:send_session_data` config is set to `false`.
    # @return [nil] if the {#request} object doesn't respond to `#session`.
    # @return [nil] if the {#request} session data is `nil`.
    # @return [Hash<String, Object>]
    def sanitized_session_data
      return unless Appsignal.config[:send_session_data]

      Appsignal::Utils::HashSanitizer.sanitize(
        session_data&.to_hash, Appsignal.config[:filter_session_data]
      )
    end

    # Returns sanitized metadata set on the request environment.
    #
    # @return [Hash<String, Object>]
    def sanitized_metadata
      env = environment
      return unless env

      metadata = env[:metadata]
      return unless metadata

      metadata
        .transform_keys(&:to_s)
        .reject { |key, _value| Appsignal.config[:filter_metadata].include?(key) }
    end

    def environment
      if @headers
        if @headers.respond_to? :call
          @headers.call
        else
          @headers
        end
      elsif request.respond_to?(:env)
        request.env
      end
    rescue => e
      Appsignal.internal_logger.error \
        "Exception while fetching headers: #{e.class}: #{e}"
      nil
    end

    # Returns sanitized environment for a transaction.
    #
    # The environment of a transaction can contain a lot of information, not
    # all of it useful for debugging.
    #
    # @return [nil] if no environment is present.
    # @return [Hash<String, Object>]
    def sanitized_environment
      env = environment
      return unless env
      return unless env.respond_to?(:empty?)
      return if env.empty?

      {}.tap do |out|
        Appsignal.config[:request_headers].each do |key|
          out[key] = env[key] if env[key]
        end
      end
    end

    # Only keep tags if they meet the following criteria:
    # * Key is a symbol or string with less then 100 chars
    # * Value is a symbol or string with less then 100 chars
    # * Value is an integer
    #
    # @see https://docs.appsignal.com/ruby/instrumentation/tagging.html
    def sanitized_tags
      @tags.select do |key, value|
        ALLOWED_TAG_KEY_TYPES.any? { |type| key.is_a? type } &&
          ALLOWED_TAG_VALUE_TYPES.any? { |type| value.is_a? type }
      end
    end

    def cleaned_backtrace(backtrace)
      if defined?(::Rails) && Rails.respond_to?(:backtrace_cleaner) && backtrace
        ::Rails.backtrace_cleaner.clean(backtrace, nil)
      else
        backtrace
      end
    end

    # Clean error messages that are known to potentially contain user data.
    # Returns an unchanged message otherwise.
    def cleaned_error_message(error)
      case error.class.to_s
      when "PG::UniqueViolation", "ActiveRecord::RecordNotUnique"
        error.message.to_s.gsub(/\)=\(.*\)/, ")=(?)")
      else
        error.message.to_s
      end
    end

    # Stub that is returned by {Transaction.current} if there is no current
    # transaction, so that it's still safe to call methods on it if there is no
    # current transaction.
    class NilTransaction
      def method_missing(_method, *args, &block)
      end

      # Instrument should still yield
      def instrument(*_args)
        yield
      end

      def nil_transaction?
        true
      end
    end
  end
end
