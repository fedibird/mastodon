# frozen_string_literal: true

# Remote mute identity uses TagManager's normalized domain, never a cache id.
class EmojiMutes::Domain
  def self.normalize(domain)
    return if domain.blank?

    TagManager.instance.normalize_domain(domain.to_s.strip)
  rescue Addressable::URI::InvalidURIError, IDN::Idna::IdnaError, ArgumentError
    nil
  end

  def self.same?(left, right)
    normalized = normalize(left)
    other = normalize(right)
    normalized.present? && normalized == other
  end

  def self.forms(domain)
    normalized = normalize(domain)
    return [] if normalized.blank?

    unicode = Addressable::IDNA.to_unicode(normalized)
    [normalized, unicode, domain.to_s.downcase].uniq
  rescue Addressable::IDNA::PunycodeBigOutput, ArgumentError
    [normalized, domain.to_s.downcase].uniq
  end
end
