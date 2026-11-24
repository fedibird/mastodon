# frozen_string_literal: true

class HashtagMutes::UpsertService < BaseService
  # Relative durations offered from the hashtag menu. Nil is indefinite.
  # Expiry is stored on CustomFilter and applied by comparing expires_at with
  # the current time, so extending or clearing it cannot be undone by an
  # older scheduled job.
  # preserve_expiry keeps the stored end time. An explicit mute still
  # forces hide. Context, keywords, and individual posts stay as they are.
  def call(account, name:, expires_in: nil, preserve_expiry: false)
    normalized = CustomFilterTag.normalize_name(name)
    raise Mastodon::ValidationError, I18n.t('filters.errors.invalid_hashtag') if normalized.blank?

    duration = preserve_expiry ? nil : normalize_duration(expires_in)
    upsert_with_retry(account, normalized, duration, name, preserve_expiry)
  end

  private

  def upsert_with_retry(account, normalized, duration, raw_name, preserve_expiry)
    attempt = 0

    begin
      attempt += 1
      upsert!(account, normalized, duration, raw_name, preserve_expiry)
    rescue ActiveRecord::RecordNotUnique
      retry if attempt < 2

      raise
    end
  end

  def upsert!(account, normalized, duration, raw_name, preserve_expiry)
    ApplicationRecord.transaction do
      rule = CustomFilterTag.find_by(account_id: account.id, name: normalized)

      filter = if rule
                 rule.custom_filter.tap do |existing|
                   raise ActiveRecord::RecordNotFound if existing.nil? || existing.account_id != account.id
                   raise Mastodon::ValidationError, I18n.t('filters.errors.expired_hashtag_preserve') if preserve_expiry && !CustomFilter.still_active?(existing)

                   existing.action = :hide
                   existing.expires_in = duration unless preserve_expiry
                   existing.save!
                 end
               else
                 account.custom_filters.create!(
                   title: "##{CustomFilterTag.display_name(raw_name)}",
                   context: CustomFilter::VALID_CONTEXTS,
                   action: :hide,
                   expires_in: duration
                 ).tap do |created|
                   created.filter_tags.create!(account: account, name: normalized)
                 end
               end

      filter
    end
  end

  def normalize_duration(value)
    return nil if value.nil? || value == ''

    seconds = integer_seconds(value)
    return nil if seconds.zero?
    return seconds if CustomFilter::HASHTAG_MUTE_DURATIONS.map(&:to_i).include?(seconds)

    raise Mastodon::ValidationError, I18n.t('filters.errors.invalid_hashtag_duration')
  end

  def integer_seconds(value)
    case value
    when Integer
      value
    when String
      stripped = value.strip
      raise ArgumentError unless stripped.match?(/\A-?\d+\z/)

      stripped.to_i
    else
      raise ArgumentError
    end
  rescue ArgumentError
    raise Mastodon::ValidationError, I18n.t('filters.errors.invalid_hashtag_duration')
  end
end
