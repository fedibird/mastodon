# frozen_string_literal: true

module PostDrafts
  module ContextFields
    SOURCE_ID = /\A[A-Za-z0-9_.:-]{1,80}\z/

    private

    def context(value)
      return nil if value.nil?

      require_object!(value, 'input.context')
      reject_unknown!(value, %w(key resolved_account_id source managed suppressions requirements constraints protocol), 'input.context')
      {
        'key' => label(value['key'], 'input.context.key'),
        'resolved_account_id' => reference(value['resolved_account_id'], 'input.context.resolved_account_id'),
        'source' => context_source(value['source']),
        'managed' => managed(value['managed']),
        'suppressions' => suppressions(value['suppressions']),
        'requirements' => requirements(value['requirements']),
        'constraints' => constraints(value['constraints']),
        'protocol' => protocol(value['protocol']),
      }
    end

    def context_source(value)
      return nil if value.nil?

      require_object!(value, 'input.context.source')
      reject_unknown!(value, %w(id revision), 'input.context.source')
      {
        'id' => source_id(value['id'], 'input.context.source.id'),
        'revision' => small_integer(value['revision'], 'input.context.source.revision'),
      }
    end

    def source_id(value, key)
      return nil if value.nil?
      fail!('invalid_reference', key) unless value.is_a?(String) && SOURCE_ID.match?(value)

      value
    end

    def small_integer(value, key)
      return nil if value.nil?
      fail!('invalid_type', key) unless value.is_a?(Integer)
      fail!('invalid_format', key) unless value.between?(0, 1_000_000_000)

      value
    end

    def managed(value)
      raw = value.is_a?(Hash) ? value : {}
      fail!('invalid_type', 'input.context.managed') unless value.nil? || value.is_a?(Hash)
      reject_unknown!(raw, %w(hashtags mentions), 'input.context.managed') unless raw.empty?
      {
        'hashtags' => record_list(raw['hashtags'], 'input.context.managed.hashtags', %w(name normalizedName enforcement ruleId)),
        'mentions' => record_list(raw['mentions'], 'input.context.managed.mentions', %w(accountId acct enforcement ruleId placement)),
      }
    end

    def record_list(value, key, fields)
      return [] if value.nil?
      fail!('invalid_type', key) unless value.is_a?(Array)
      fail!('too_many', key) if value.size > Payload::LIST_MAX
      value.map { |item| record(item, key, fields) }
    end

    def record(value, key, fields)
      require_object!(value, key)
      reject_unknown!(value, fields, key)
      fields.index_with { |field| record_value(value[field], "#{key}.#{field}") }
    end

    def record_value(value, key)
      return nil if value.nil?
      return value if value.is_a?(Integer) && value.between?(0, 1_000_000_000)
      return value if [true, false].include?(value)

      bounded_string(value, key, Payload::SHORT_TEXT_MAX, default: nil)
    end

    def suppressions(value)
      return { 'hashtags' => [] } if value.nil?

      require_object!(value, 'input.context.suppressions')
      reject_unknown!(value, %w(hashtags), 'input.context.suppressions')
      { 'hashtags' => string_list(value['hashtags'], 'input.context.suppressions.hashtags') }
    end

    def string_list(value, key)
      return [] if value.nil?
      fail!('invalid_type', key) unless value.is_a?(Array)
      fail!('too_many', key) if value.size > Payload::LIST_MAX
      value.map { |item| bounded_string(item, key, 200, default: '') }
    end

    def requirements(value)
      return { 'following_accounts' => [] } if value.nil?

      require_object!(value, 'input.context.requirements')
      reject_unknown!(value, %w(following_accounts), 'input.context.requirements')
      {
        'following_accounts' => record_list(value['following_accounts'], 'input.context.requirements.following_accounts', %w(accountId acct enforcement ruleId)),
      }
    end

    def constraints(value)
      return { 'allowed_visibilities' => nil } if value.nil?

      require_object!(value, 'input.context.constraints')
      reject_unknown!(value, %w(allowed_visibilities), 'input.context.constraints')
      allowed = value['allowed_visibilities']
      {
        'allowed_visibilities' => allowed.nil? ? nil : string_list(allowed, 'input.context.constraints.allowed_visibilities'),
      }
    end

    def protocol(value)
      return { 'activity_pub' => { 'audience' => nil } } if value.nil?

      require_object!(value, 'input.context.protocol')
      reject_unknown!(value, %w(activity_pub), 'input.context.protocol')
      { 'activity_pub' => activity_pub_audience(value['activity_pub']) }
    end

    # P0 always writes `{ activity_pub: { audience: null | record } }`.
    # `activity_pub` is the wrapper. The audience record is the inner value.
    def activity_pub_audience(value)
      return { 'audience' => nil } if value.nil?

      require_object!(value, 'input.context.protocol.activity_pub')
      reject_unknown!(value, %w(audience), 'input.context.protocol.activity_pub')
      audience = value['audience']
      {
        'audience' => audience.nil? ? nil : record(audience, 'input.context.protocol.activity_pub.audience', %w(accountId acct enforcement ruleId)),
      }
    end
  end
end
