# frozen_string_literal: true

module PostDrafts
  # Accepts a P0 schema v1 snapshot body. Unknown fields are rejected so a
  # client cannot store Redux state, HTML, tokens, or permission caches.
  # Non-empty media is rejected until a later change retains attachments.
  class Payload
    include ContextFields
    include StyleFields

    class Invalid < StandardError
      attr_reader :errors

      def initialize(errors)
        @errors = errors
        super('Invalid draft')
      end
    end

    MAX_BYTES = 32_768
    TEXT_MAX = 10_000
    SHORT_TEXT_MAX = 500
    LIST_MAX = 20
    UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
    ID_PATTERN = /\A[1-9][0-9]{0,18}\z/
    TOKEN_PATTERN = /\A[a-z0-9_]{1,32}\z/
    LANGUAGE_PATTERN = /\A[a-z]{2,3}(?:-[A-Za-z0-9]{2,8}){0,3}\z/
    URL_PATTERN = /\Ahttps?:\/\/[^\s[:cntrl:]]{1,2000}\z/
    FORBIDDEN = %w(
      html token access_token authorization idempotency_key suggestions
      materialized_text interactioncheck permissions password secret private_key refresh_token
    ).freeze
    TOP_KEYS = %w(
      schema_version composer_id media_incomplete content_hash input
      account_id client_draft_uuid saved_at
    ).freeze
    INPUT_KEYS = %w(
      text spoiler spoiler_text privacy searchability searchability_manual
      searchability_desired privacy_before_searchability circle_id language
      sensitive in_reply_to_id quote_id quote_url references context_references
      ignore_reference_check poll scheduled expires expires_action media context
      posting_context_account_id surface user_posting_style sender
    ).freeze

    def self.normalize(raw, owner_account_id:, client_uuid:)
      new(raw, owner_account_id, client_uuid).normalize
    end

    def self.client_uuid!(value)
      uuid = value.to_s.downcase
      raise Invalid, [{ 'code' => 'invalid_uuid', 'key' => 'client_uuid' }] unless UUID_PATTERN.match?(uuid)

      uuid
    end

    def self.same?(left, right)
      canonical(left) == canonical(right)
    end

    def self.canonical(value)
      JSON.generate(sort_keys(value))
    end

    def self.sort_keys(value)
      case value
      when Hash
        value.map { |key, item| [key.to_s, sort_keys(item)] }.sort.to_h
      when Array
        value.map { |item| sort_keys(item) }
      else
        value
      end
    end

    def initialize(raw, owner_account_id, client_uuid)
      @raw = raw
      @owner_account_id = owner_account_id.to_s
      @client_uuid = client_uuid
    end

    def normalize
      require_object!(@raw, 'payload')
      reject_unknown!(@raw, TOP_KEYS, 'payload')
      reject_forbidden!(@raw, 'payload')
      reject_size!(@raw)
      owner!
      embedded_uuid!
      result = {
        'schema_version' => schema_version,
        'composer_id' => composer_id,
        'media_incomplete' => flag(@raw['media_incomplete'], 'media_incomplete'),
        'content_hash' => content_hash,
        'input' => input,
      }
      reject_size!(result)
      result
    end

    private

    def fail!(code, key)
      raise Invalid, [{ 'code' => code, 'key' => key }]
    end

    def require_object!(value, key)
      fail!('invalid_type', key) unless value.is_a?(Hash)
    end

    def reject_unknown!(hash, allowed, prefix)
      extra = hash.keys.map(&:to_s) - allowed
      fail!('unknown_field', [prefix, extra.first].compact.join('.')) if extra.any?
    end

    def reject_forbidden!(value, key, depth = 0)
      fail!('too_deep', key) if depth > 8

      case value
      when Hash
        reject_forbidden_hash!(value, key, depth)
      when Array
        fail!('too_many', key) if value.size > LIST_MAX
        value.each_with_index { |item, index| reject_forbidden!(item, "#{key}[#{index}]", depth + 1) }
      end
    end

    def reject_forbidden_hash!(hash, key, depth)
      hash.each do |child, nested|
        name = child.to_s
        fail!('forbidden_field', "#{key}.#{name}") if FORBIDDEN.include?(name.downcase)
        reject_forbidden!(nested, "#{key}.#{name}", depth + 1)
      end
    end

    def reject_size!(value)
      fail!('too_large', 'payload') if JSON.generate(value).bytesize > MAX_BYTES
    end

    def owner!
      return if @raw['account_id'].nil?
      return if @raw['account_id'].to_s == @owner_account_id

      fail!('owner_mismatch', 'account_id')
    end

    def embedded_uuid!
      return if @raw['client_draft_uuid'].nil?
      return if @raw['client_draft_uuid'].to_s.downcase == @client_uuid

      fail!('uuid_mismatch', 'client_draft_uuid')
    end

    def schema_version
      fail!('unsupported_schema', 'schema_version') unless @raw['schema_version'] == PostDraft::SCHEMA_VERSION

      PostDraft::SCHEMA_VERSION
    end

    def composer_id
      value = @raw['composer_id']
      return nil if value.nil?
      fail!('invalid_format', 'composer_id') unless value.is_a?(String) && value.match?(/\A[A-Za-z0-9_:-]{1,64}\z/)

      value
    end

    def content_hash
      value = @raw['content_hash']
      return nil if value.nil?
      fail!('invalid_format', 'content_hash') unless value.is_a?(String) && value.match?(/\A[A-Za-z0-9:_-]{1,128}\z/)

      value
    end

    def flag(value, key)
      return false if value.nil?
      fail!('invalid_type', key) unless [true, false].include?(value)

      value
    end

    def input
      raw = @raw['input']
      require_object!(raw, 'input')
      reject_unknown!(raw, INPUT_KEYS, 'input')
      text_fields(raw).merge(choice_fields(raw)).merge(relation_fields(raw)).merge(nested_fields(raw))
    end

    def text_fields(raw)
      {
        'text' => bounded_string(raw['text'], 'input.text', TEXT_MAX, default: ''),
        'spoiler' => flag(raw['spoiler'], 'input.spoiler'),
        'spoiler_text' => bounded_string(raw['spoiler_text'], 'input.spoiler_text', SHORT_TEXT_MAX, default: ''),
        'sensitive' => flag(raw['sensitive'], 'input.sensitive'),
        'language' => language(raw['language']),
      }
    end

    def choice_fields(raw)
      {
        'privacy' => enum_value(raw['privacy'], 'input.privacy', Status.visibilities.keys),
        'searchability' => enum_value(raw['searchability'], 'input.searchability', Status.searchabilities.keys),
        'searchability_manual' => flag(raw['searchability_manual'], 'input.searchability_manual'),
        'searchability_desired' => enum_value(raw['searchability_desired'], 'input.searchability_desired', Status.searchabilities.keys),
        'privacy_before_searchability' => enum_value(raw['privacy_before_searchability'], 'input.privacy_before_searchability', Status.visibilities.keys),
        'ignore_reference_check' => flag(raw['ignore_reference_check'], 'input.ignore_reference_check'),
      }
    end

    def relation_fields(raw)
      {
        'circle_id' => reference(raw['circle_id'], 'input.circle_id'),
        'in_reply_to_id' => reference(raw['in_reply_to_id'], 'input.in_reply_to_id'),
        'quote_id' => reference(raw['quote_id'], 'input.quote_id'),
        'quote_url' => quote_url(raw['quote_url']),
        'references' => reference_list(raw['references'], 'input.references'),
        'context_references' => reference_list(raw['context_references'], 'input.context_references'),
        'posting_context_account_id' => reference(raw['posting_context_account_id'], 'input.posting_context_account_id'),
        'scheduled' => plain_text(raw['scheduled'], 'input.scheduled'),
        'expires' => plain_text(raw['expires'], 'input.expires'),
        'expires_action' => token(raw['expires_action'], 'input.expires_action'),
      }
    end

    def nested_fields(raw)
      {
        'poll' => poll(raw['poll']),
        'media' => media(raw['media']),
        'context' => context(raw['context']),
        'surface' => surface(raw['surface']),
        'user_posting_style' => style(raw['user_posting_style']),
        'sender' => sender(raw['sender']),
      }
    end

    def bounded_string(value, key, max, default:)
      return default if value.nil?
      fail!('invalid_type', key) unless value.is_a?(String)
      fail!('too_long', key) if value.length > max
      fail!('invalid_format', key) if value.match?(/[[:cntrl:]]/)

      value
    end

    def plain_text(value, key)
      bounded_string(value, key, 64, default: nil)
    end

    def token(value, key)
      return nil if value.nil?
      fail!('invalid_format', key) unless value.is_a?(String) && TOKEN_PATTERN.match?(value)

      value
    end

    def language(value)
      return nil if value.nil?
      fail!('invalid_format', 'input.language') unless value.is_a?(String) && LANGUAGE_PATTERN.match?(value)

      value
    end

    def enum_value(value, key, allowed)
      return nil if value.nil?
      fail!('invalid_format', key) unless value.is_a?(String) && allowed.include?(value)

      value
    end

    def reference(value, key)
      return nil if value.nil?
      fail!('invalid_reference', key) unless value.is_a?(String) && ID_PATTERN.match?(value)

      value
    end

    def reference_list(value, key)
      return [] if value.nil?
      fail!('invalid_type', key) unless value.is_a?(Array)
      fail!('too_many', key) if value.size > LIST_MAX
      value.map { |item| reference(item, key) }
    end

    def quote_url(value)
      return nil if value.nil?
      fail!('invalid_format', 'input.quote_url') unless value.is_a?(String) && URL_PATTERN.match?(value)

      value
    end

    def media(value)
      return [] if value.nil?
      fail!('invalid_type', 'input.media') unless value.is_a?(Array)
      fail!('media_not_retained', 'input.media') if value.any?

      []
    end

    def poll(value)
      return nil if value.nil?

      require_object!(value, 'input.poll')
      reject_unknown!(value, %w(options expires_in multiple), 'input.poll')
      options = poll_options(value['options'])
      {
        'options' => options,
        'expires_in' => poll_expires(value['expires_in']),
        'multiple' => flag(value['multiple'], 'input.poll.multiple'),
      }
    end

    def poll_options(value)
      fail!('invalid_type', 'input.poll.options') unless value.is_a?(Array)
      fail!('too_many', 'input.poll.options') if value.size > PollOptionsValidator::MAX_OPTIONS_LIMIT
      value.map do |option|
        fail!('invalid_type', 'input.poll.options') unless option.is_a?(String)

        bounded_string(option, 'input.poll.options', PollOptionsValidator::MAX_OPTION_CHARS, default: '')
      end
    end

    def poll_expires(value)
      return nil if value.nil?
      fail!('invalid_type', 'input.poll.expires_in') unless value.is_a?(Integer)
      fail!('invalid_format', 'input.poll.expires_in') unless value.between?(0, 1.month.to_i)

      value
    end

    def surface(value)
      return nil if value.nil?

      require_object!(value, 'input.surface')
      reject_unknown!(value, %w(kind key), 'input.surface')
      kind = token(value['kind'], 'input.surface.kind')
      key = bounded_string(value['key'], 'input.surface.key', 200, default: nil)
      fail!('invalid_format', 'input.surface') if kind.nil? || key.nil?
      { 'kind' => kind, 'key' => key }
    end

    def sender(value)
      return { 'id' => nil, 'selection_origin' => nil } if value.nil?

      require_object!(value, 'input.sender')
      reject_unknown!(value, %w(id selection_origin), 'input.sender')
      {
        'id' => reference(value['id'], 'input.sender.id'),
        'selection_origin' => token(value['selection_origin'], 'input.sender.selection_origin'),
      }
    end
  end
end
