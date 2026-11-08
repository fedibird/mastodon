# frozen_string_literal: true

# Resolve a typed reference without fetching remote URLs, copying emoji,
# or writing the database. A missing remote cache row stays unfetched.
class EmojiReferences::Resolver
  def resolve(emoji)
    parsed = EmojiReferences::Parser.new.parse(emoji)
    parsed.unicode? ? resolve_unicode(parsed) : resolve_custom(parsed)
  end

  private

  def resolve_unicode(parsed)
    emoji = PersonalEmojiSets::UnicodeCatalog.find(parsed.native)
    invalid!('emoji.native', 'invalid_unicode') unless emoji

    EmojiReferences::Result.new(
      reference: { kind: 'unicode', native: parsed.native },
      detail: EmojiReferences::Detail.new.unicode(parsed.native, emoji),
      addable: true
    )
  end

  def resolve_custom(parsed)
    parsed.remote? ? resolve_remote(parsed) : resolve_local(parsed)
  end

  def resolve_local(parsed)
    record = local_record(parsed)
    invalid!('emoji.scope', 'contradictory_scope') unless record.local?
    invalid!('emoji.shortcode', 'contradictory_field') if parsed.shortcode && parsed.shortcode != record.shortcode

    EmojiReferences::Result.new(
      reference: { kind: 'custom', scope: 'local', custom_emoji_id: record.id.to_s, shortcode: record.shortcode },
      detail: EmojiReferences::Detail.new.custom(record),
      addable: !record.disabled?,
      add_reason: record.disabled? ? 'disabled' : nil
    )
  end

  def resolve_remote(parsed)
    record = remote_record(parsed)
    reference = { kind: 'custom', scope: 'remote', domain: parsed.domain, shortcode: record ? record.shortcode : parsed.shortcode }
    if record
      EmojiReferences::Result.new(reference: reference, detail: EmojiReferences::Detail.new.custom(record), addable: false, add_reason: 'remote_emoji')
    else
      EmojiReferences::Result.new(
        reference: reference,
        detail: EmojiReferences::Detail.new.unfetched(parsed.domain, parsed.shortcode),
        addable: false,
        add_reason: 'remote_emoji'
      )
    end
  end

  def local_record(parsed)
    record = if parsed.custom_emoji_id
               CustomEmoji.includes(:category).find_by(id: parsed.custom_emoji_id)
             else
               CustomEmoji.local.includes(:category).find_by(shortcode: parsed.shortcode)
             end
    invalid!(parsed.custom_emoji_id ? 'emoji.custom_emoji_id' : 'emoji.shortcode', 'unavailable_emoji') unless record
    record
  end

  def remote_record(parsed)
    records = CustomEmoji.remote.includes(:category).where(shortcode: parsed.shortcode).where(domain: remote_domains(parsed.domain)).to_a
    records.find { |emoji| emoji.domain == parsed.domain } || records.min_by(&:id)
  end

  # Stored rows may keep the unicode hostname. The returned reference still
  # uses the normalized domain, which is the stable identity.
  def remote_domains(domain)
    [domain, Addressable::IDNA.to_unicode(domain)].uniq
  end

  def invalid!(path, code)
    raise EmojiReferences::Invalid.new(path, code)
  end
end
