# frozen_string_literal: true

# Structural checks for a typed emoji reference. This does not read or
# write emoji rows. An empty or invalid remote domain is rejected here
# and is never rewritten as a local shortcode.
class EmojiReferences::Parser
  UNICODE_FIELDS = %w(kind native).freeze
  CUSTOM_FIELDS = %w(kind scope custom_emoji_id shortcode domain).freeze
  MAX_NATIVE_BYTES = 128
  MAX_DOMAIN_BYTES = 253
  MAX_SHORTCODE_BYTES = 100
  DOMAIN_PATTERN = /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*\z/.freeze

  def parse(value)
    invalid!('emoji', 'invalid_type') unless value.is_a?(Hash)

    kind = value['kind']
    invalid!('emoji.kind', 'invalid_kind') unless %w(unicode custom).include?(kind)
    kind == 'unicode' ? parse_unicode(value) : parse_custom(value)
  end

  private

  def parse_unicode(value)
    fields!(value, UNICODE_FIELDS)
    native = value['native']
    invalid!('emoji.native', 'invalid_unicode') unless native.is_a?(String) && native.bytesize.between?(1, MAX_NATIVE_BYTES)

    EmojiReferences::Parsed.new(kind: 'unicode', native: native)
  end

  def parse_custom(value)
    fields!(value, CUSTOM_FIELDS)
    scope = value['scope']
    invalid!('emoji.scope', 'invalid_scope') if value.key?('scope') && !%w(local remote).include?(scope)
    remote_shape?(value, scope) ? parse_remote(value, scope) : parse_local(value)
  end

  def remote_shape?(value, scope)
    scope == 'remote' || value.key?('domain')
  end

  def parse_remote(value, scope)
    invalid!('emoji.scope', 'contradictory_scope') if scope == 'local'
    invalid!('emoji.custom_emoji_id', 'contradictory_field') if value.key?('custom_emoji_id')
    invalid!('emoji.domain', 'invalid_domain') unless value.key?('domain')

    EmojiReferences::Parsed.new(
      kind: 'custom',
      scope: 'remote',
      domain: normalize_domain(value['domain']),
      shortcode: required_shortcode(value, local: false)
    )
  end

  def parse_local(value)
    id = optional_id(value)
    shortcode = optional_shortcode(value, required: id.nil?)
    invalid!('emoji', 'invalid_reference') if id.nil? && shortcode.nil?

    EmojiReferences::Parsed.new(kind: 'custom', scope: 'local', custom_emoji_id: id, shortcode: shortcode)
  end

  def normalize_domain(domain)
    invalid!('emoji.domain', 'invalid_domain') unless domain.is_a?(String)

    stripped = domain.strip
    invalid!('emoji.domain', 'invalid_domain') if stripped.blank? || stripped.bytesize > MAX_DOMAIN_BYTES || stripped.match?(/[[:space:]\/\\@#?]/)
    normalized = TagManager.instance.normalize_domain(stripped)
    invalid!('emoji.domain', 'invalid_domain') if normalized.blank? || !DOMAIN_PATTERN.match?(normalized)
    invalid!('emoji.domain', 'invalid_domain') if TagManager.instance.local_domain?(normalized)
    normalized
  rescue Addressable::URI::InvalidURIError, IDN::Idna::IdnaError, ArgumentError
    invalid!('emoji.domain', 'invalid_domain')
  end

  def optional_id(value)
    return nil unless value.key?('custom_emoji_id')

    id = value['custom_emoji_id']
    valid = id.is_a?(String) && PersonalEmojiSets::Definition::DATABASE_ID_PATTERN.match?(id) && id.to_i <= PersonalEmojiSets::Definition::MAX_DATABASE_ID
    invalid!('emoji.custom_emoji_id', 'invalid_id') unless valid
    id
  end

  def optional_shortcode(value, required:)
    return nil unless required || value.key?('shortcode')

    required_shortcode(value, local: true)
  end

  def required_shortcode(value, local:)
    shortcode = value['shortcode']
    invalid!('emoji.shortcode', 'invalid_shortcode') unless valid_shortcode?(shortcode, local: local)
    shortcode
  end

  def valid_shortcode?(shortcode, local:)
    return false unless shortcode.is_a?(String)
    return false if shortcode.bytesize > MAX_SHORTCODE_BYTES
    return false unless /\A#{CustomEmoji::SHORTCODE_RE_FRAGMENT}\z/.match?(shortcode)
    return false if local && shortcode.length < 2

    true
  end

  def fields!(value, allowed)
    invalid!('emoji', 'unknown_field') unless (value.keys - allowed).empty?
  end

  def invalid!(path, code)
    raise EmojiReferences::Invalid.new(path, code)
  end
end
