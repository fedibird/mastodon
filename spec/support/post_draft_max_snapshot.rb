# frozen_string_literal: true

# Snapshot that fills every field cap. It is larger than the 256 KiB storage
# budget and the API rejects it. Text uses a 4-byte character.
module PostDraftMaxSnapshot
  UUID = '11111111-1111-4111-8111-111111111111'
  WIDE = '😀'

  module_function

  def request_body
    input = max_input
    {
      'schema_version' => 1,
      'composer_id' => wide(PostDrafts::Payload::LABEL_MAX),
      'media_incomplete' => false,
      'content_hash' => stable_stringify('input' => input, 'media_incomplete' => false),
      'account_id' => '42',
      'client_draft_uuid' => UUID,
      'saved_at' => '2026-11-14T00:00:00.000Z',
      'input' => input,
    }
  end

  def max_input
    {
      'text' => wide(PostDrafts::Payload::TEXT_MAX),
      'spoiler' => true,
      'spoiler_text' => wide(PostDrafts::Payload::SHORT_TEXT_MAX),
      'privacy' => 'public',
      'searchability' => 'public',
      'searchability_manual' => true,
      'searchability_desired' => 'public',
      'privacy_before_searchability' => 'public',
      'circle_id' => snowflake,
      'language' => 'ja',
      'sensitive' => true,
      'in_reply_to_id' => snowflake,
      'quote_id' => snowflake,
      'quote_url' => "https://#{'a' * 2000}",
      'references' => Array.new(PostDrafts::Payload::LIST_MAX, snowflake),
      'context_references' => Array.new(PostDrafts::Payload::LIST_MAX, snowflake),
      'ignore_reference_check' => true,
      'poll' => {
        'options' => Array.new(PollOptionsValidator::MAX_OPTIONS_LIMIT, wide(PollOptionsValidator::MAX_OPTION_CHARS)),
        'expires_in' => 1.month.to_i,
        'multiple' => true,
      },
      'scheduled' => 's' * 64,
      'expires' => 'e' * 64,
      'expires_action' => 'mark',
      'media' => [],
      'context' => max_context,
      'posting_context_account_id' => snowflake,
      'surface' => { 'kind' => 'hashtag', 'key' => wide(PostDrafts::Payload::LABEL_MAX) },
      'user_posting_style' => max_style,
      'sender' => { 'id' => "local:#{snowflake}", 'selection_origin' => 'a' * 32 },
    }
  end

  def max_context
    {
      'key' => wide(PostDrafts::Payload::LABEL_MAX),
      'resolved_account_id' => snowflake,
      'source' => { 'id' => 'a' * 80, 'revision' => 1_000_000_000 },
      'managed' => max_managed,
      'suppressions' => { 'hashtags' => wide_list(200) },
      'requirements' => {
        'following_accounts' => Array.new(PostDrafts::Payload::LIST_MAX) { record(%w(accountId acct enforcement ruleId)) },
      },
      'constraints' => { 'allowed_visibilities' => wide_list(200) },
      'protocol' => {
        'activity_pub' => {
          'audience' => record(%w(accountId acct enforcement ruleId)),
        },
      },
    }
  end

  def max_style
    {
      'selected_id' => snowflake,
      'applied_revision' => 1_000_000_000,
      'usage_mode' => 'a' * 32,
      'selection_kind' => 'b' * 32,
      'selection_origin' => 'c' * 32,
      'manual_fields' => wide_list(200),
      'manual_values' => wide_hash,
      'suppressions' => wide_list(200),
      'style_owned_fields' => wide_list(200),
      'unapplied' => wide_list(200),
      'destination_source' => 'd' * 32,
      'destination_policy' => 'e' * 32,
      'destination_account_id' => snowflake,
      'destination_status' => 'f' * 32,
      'snapshot' => {
        'id' => snowflake,
        'name' => wide(200),
        'revision' => 1_000_000_000,
        'target' => wide_hash,
        'defaults' => wide_hash,
        'managed' => max_managed,
      },
    }
  end

  def max_managed
    {
      'hashtags' => Array.new(PostDrafts::Payload::LIST_MAX) { record(%w(name normalizedName enforcement ruleId)) },
      'mentions' => Array.new(PostDrafts::Payload::LIST_MAX) { record(%w(accountId acct enforcement ruleId placement)) },
    }
  end

  def record(fields)
    fields.index_with { wide(PostDrafts::Payload::SHORT_TEXT_MAX) }
  end

  def wide_list(length)
    Array.new(PostDrafts::Payload::LIST_MAX, wide(length))
  end

  def wide_hash
    Array.new(PostDrafts::Payload::LIST_MAX) { |index| ["k#{index}#{'x' * 60}", wide(PostDrafts::Payload::SHORT_TEXT_MAX)] }.to_h
  end

  def wide(length)
    WIDE * length
  end

  def snowflake
    '9' * 19
  end

  # Same encoding as app/javascript/mastodon/drafts/snapshot.js stableStringify.
  def stable_stringify(value)
    case value
    when Array
      "[#{value.map { |item| stable_stringify(item) }.join(',')}]"
    when Hash
      "{#{value.keys.map(&:to_s).sort.map { |key| "#{JSON.generate(key)}:#{stable_stringify(value[key])}" }.join(',')}}"
    else
      JSON.generate(value.nil? ? nil : value)
    end
  end
end
