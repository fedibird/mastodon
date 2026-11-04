# frozen_string_literal: true

module FeedDelivery
  # Versioned keyword evidence stored in the Sidekiq argument.
  #
  # The payload is ids and generations only. It must not contain status text,
  # keywords, regexp source, or other subscription settings. A missing
  # ignore-block id means "not proven", not "no ignore-block rule matched".
  class Evidence
    VERSION = 1
    REASON = 'keyword'

    attr_accessor :subscription_id, :subscription_updated_at, :account_id, :list_id, :status_id,
                  :status_edited_at
    attr_reader :ignore_block_subscription_id, :ignore_block_subscription_updated_at

    def self.from_job_options(options)
      return nil unless options.is_a?(Hash)

      reason = value(options, :reason).to_s
      return nil if reason.empty?
      return nil unless reason == REASON
      return nil unless value(options, :v).to_i == VERSION

      raw = value(options, :evidence)
      return nil unless raw.is_a?(Hash)

      from_hash(raw.symbolize_keys)
    rescue ArgumentError, TypeError
      nil
    end

    def self.build(subscription:, ignore_block_subscription:, status:)
      evidence = new
      evidence.subscription_id = subscription.id
      evidence.subscription_updated_at = FeedDelivery.usec(subscription.updated_at)
      evidence.account_id = subscription.account_id
      evidence.list_id = subscription.list_id
      evidence.status_id = status.id
      evidence.status_edited_at = FeedDelivery.usec(status.edited_at)
      evidence.attach_ignore_block(ignore_block_subscription)
      evidence
    end

    def self.from_hash(raw)
      evidence = new
      evidence.subscription_id = positive_integer(raw[:subscription_id])
      evidence.subscription_updated_at = usec_value(raw[:subscription_updated_at])
      evidence.account_id = positive_integer(raw[:account_id])
      evidence.list_id = optional_id(raw, :list_id)
      evidence.status_id = positive_integer(raw[:status_id])
      evidence.status_edited_at = optional_usec(raw, :status_edited_at)
      return nil unless evidence.required_present?

      evidence.attach_ignore_block_ids(raw)
    rescue ArgumentError, TypeError
      nil
    end

    def self.value(options, key)
      options[key].nil? ? options[key.to_s] : options[key]
    end

    def self.positive_integer(value)
      integer = strict_integer(value)
      return nil if integer.nil? || integer <= 0

      integer
    end

    def self.usec_value(value)
      integer = strict_integer(value)
      return nil if integer.nil? || integer.negative?

      integer
    end

    def self.optional_id(raw, key)
      return :missing unless raw.key?(key)
      return nil if raw[key].nil?

      positive_integer(raw[key]) || :invalid
    end

    def self.optional_usec(raw, key)
      return :missing unless raw.key?(key)
      return nil if raw[key].nil?

      usec_value(raw[key]) || :invalid
    end

    def self.strict_integer(value)
      case value
      when Integer
        value
      when String
        return nil unless value.match?(/\A\d+\z/)

        Integer(value, 10)
      end
    end

    def keyword?
      true
    end

    def to_options
      { 'v' => VERSION, 'reason' => REASON, 'evidence' => to_job }
    end

    def to_job
      job = {
        'subscription_id' => subscription_id,
        'subscription_updated_at' => subscription_updated_at,
        'account_id' => account_id,
        'list_id' => list_id,
        'status_id' => status_id,
        'status_edited_at' => status_edited_at,
      }
      return job if ignore_block_subscription_id.nil?

      job.merge(
        'ignore_block_subscription_id' => ignore_block_subscription_id,
        'ignore_block_subscription_updated_at' => ignore_block_subscription_updated_at
      )
    end

    def bound_to?(account_id:, list_id:)
      self.account_id == account_id.to_i && self.list_id == FeedDelivery.normalize_list_id(list_id)
    end

    # True only for a positive match whose subscription row and status edit are
    # unchanged. A blank ignore-block qualification is not fresh and must fall
    # back to KeywordSubscribe.match?, because another rule may still match.
    def fresh_for?(status:, account_id:, list_id:, as_ignore_block:)
      return false unless status.id == status_id
      return false unless FeedDelivery.usec(status.edited_at) == status_edited_at
      return false unless bound_to?(account_id: account_id, list_id: list_id)

      subscription = loaded_subscription(as_ignore_block)
      return false if subscription.nil?
      return false if subscription.disabled?
      return false unless subscription.account_id == self.account_id
      return false unless subscription.list_id == self.list_id
      return false unless FeedDelivery.usec(subscription.updated_at) == expected_updated_at(as_ignore_block)
      return false if as_ignore_block && !subscription.ignore_block?

      true
    end

    def required_present?
      subscription_id && subscription_updated_at && account_id && status_id &&
        list_id != :missing && list_id != :invalid &&
        status_edited_at != :missing && status_edited_at != :invalid
    end

    def attach_ignore_block(subscription)
      return if subscription.nil?

      @ignore_block_subscription_id = subscription.id
      @ignore_block_subscription_updated_at = FeedDelivery.usec(subscription.updated_at)
    end

    def attach_ignore_block_ids(raw)
      ignore_id = raw[:ignore_block_subscription_id]
      ignore_at = raw[:ignore_block_subscription_updated_at]
      return self if ignore_id.nil? && ignore_at.nil?

      @ignore_block_subscription_id = self.class.positive_integer(ignore_id)
      @ignore_block_subscription_updated_at = self.class.usec_value(ignore_at)
      return nil if ignore_block_subscription_id.nil? || ignore_block_subscription_updated_at.nil?

      self
    end

    private

    def expected_updated_at(as_ignore_block)
      as_ignore_block ? ignore_block_subscription_updated_at : subscription_updated_at
    end

    def loaded_subscription(as_ignore_block)
      id = as_ignore_block ? ignore_block_subscription_id : subscription_id
      return nil if id.nil?

      @loaded ||= {}
      @loaded[id] ||= KeywordSubscribe.find_by(id: id)
    end
  end
end
