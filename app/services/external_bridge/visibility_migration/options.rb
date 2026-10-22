# frozen_string_literal: true

module ExternalBridge
  module VisibilityMigration
    # Parsed operator input. Blank and non-numeric filters are refusals.
    # They are never treated as "every row".
    class Options
      DEFAULT_BATCH = 100
      MAX_BATCH = 1000
      DEFAULT_LIMIT = 1000
      MAX_LIMIT = 100_000
      MAX_PAUSE = 300
      TIMEOUT_PATTERN = /\A[1-9]\d{0,4}(ms|s)\z/.freeze

      attr_reader :mode, :confirm_readers_ready, :user_id, :subscription_id, :batch_size,
                  :limit, :pause, :checkpoint_path, :lock_timeout, :statement_timeout,
                  :injector, :stop_check

      def self.build(raw)
        new(raw).tap(&:validate!)
      end

      def initialize(raw)
        @raw = raw
        @mode = :dry_run
        @confirm_readers_ready = false
        @user_id = nil
        @subscription_id = nil
        @batch_size = DEFAULT_BATCH
        @limit = DEFAULT_LIMIT
        @pause = 0
        @checkpoint_path = nil
        @lock_timeout = '2s'
        @statement_timeout = '30s'
        @injector = raw[:injector]
        @stop_check = raw[:stop_check]
      end

      def apply?
        mode == :apply
      end

      def verify?
        mode == :verify
      end

      def validate!
        assign_mode
        @confirm_readers_ready = truthy(@raw[:confirm_readers_ready])
        @user_id = optional_id('user-id', @raw[:user_id])
        @subscription_id = optional_id('subscription-id', @raw[:subscription_id])
        @batch_size = bounded_integer('batch-size', @raw.fetch(:batch_size, DEFAULT_BATCH), 1, MAX_BATCH)
        @limit = bounded_integer('limit', @raw.fetch(:limit, DEFAULT_LIMIT), 1, MAX_LIMIT)
        @pause = pause_seconds(@raw.fetch(:pause, 0))
        @checkpoint_path = path_or_nil(@raw[:checkpoint])
        @lock_timeout = timeout('lock-timeout', @raw.fetch(:lock_timeout, @lock_timeout))
        @statement_timeout = timeout('statement-timeout', @raw.fetch(:statement_timeout, @statement_timeout))
        check_scope!
        check_apply!
      end

      def scope_document
        { 'user_id' => user_id, 'subscription_id' => subscription_id }
      end

      private

      def assign_mode
        apply = truthy(@raw[:apply])
        verify = truthy(@raw[:verify])
        raise Refusal.new(:mode, 'apply and verify cannot be combined') if apply && verify

        @mode = if apply
                  :apply
                elsif verify
                  :verify
                else
                  :dry_run
                end
      end

      def check_scope!
        if user_id && !User.where(id: user_id).exists?
          raise Refusal.new(:user_id, "user-id #{user_id} was not found. This is a User id, not an Account id.")
        end
        return if subscription_id.nil?

        subscription = ExternalSubscription.find_by(id: subscription_id)
        raise Refusal.new(:subscription_id, "subscription-id #{subscription_id} was not found") if subscription.nil?
        return if user_id.nil? || subscription.user_id == user_id

        raise Refusal.new(:subscription_scope, 'subscription-id does not belong to user-id')
      end

      def check_apply!
        return unless apply?

        raise Refusal.new(:checkpoint_required, 'apply requires --checkpoint') if checkpoint_path.nil?
        raise Refusal.new(:readers_unconfirmed, 'apply requires --confirm-readers-ready') unless confirm_readers_ready
        raise Refusal.new(:switch_off, 'external_bridge_external_visibility is off. Refusing to apply.') unless VisibilitySwitch.enabled?
        return if VisibilitySwitch.transition_ready?

        raise Refusal.new(:preflight, 'database preflight failed. The 200-to-201 guard is not installed. No row was changed.')
      end

      def optional_id(label, value)
        return nil if value.nil?

        text = value.to_s
        raise Refusal.new(:filter, "#{label} must be a positive integer") unless text.match?(/\A[1-9]\d*\z/)

        Integer(text, 10)
      end

      def bounded_integer(label, value, minimum, maximum)
        text = value.to_s
        raise Refusal.new(:filter, "#{label} must be an integer from #{minimum} to #{maximum}") unless text.match?(/\A[1-9]\d*\z/)

        number = Integer(text, 10)
        raise Refusal.new(:filter, "#{label} must be an integer from #{minimum} to #{maximum}") unless number.between?(minimum, maximum)

        number
      end

      def pause_seconds(value)
        text = value.to_s
        raise Refusal.new(:filter, 'pause must be a number of seconds from 0 to 300') unless text.match?(/\A\d+(\.\d+)?\z/)

        number = Float(text)
        raise Refusal.new(:filter, 'pause must be a number of seconds from 0 to 300') if number.negative? || number > MAX_PAUSE

        number
      end

      def timeout(label, value)
        text = value.to_s
        raise Refusal.new(:filter, "#{label} must look like 2s or 500ms") unless text.match?(TIMEOUT_PATTERN)

        text
      end

      def path_or_nil(value)
        return nil if value.nil? || value.to_s.empty?

        File.expand_path(value.to_s)
      end

      def truthy(value)
        ActiveModel::Type::Boolean.new.cast(value) == true
      end
    end
  end
end
