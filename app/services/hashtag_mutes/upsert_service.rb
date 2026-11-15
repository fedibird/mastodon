# frozen_string_literal: true

class HashtagMutes::UpsertService < BaseService
  # Relative durations offered from the hashtag menu. Nil is indefinite.
  # Expiry is stored on CustomFilter and applied by comparing expires_at with
  # the current time, so extending or clearing it cannot be undone by an
  # older scheduled job.
  def call(account, name:, expires_in:)
    normalized = CustomFilterTag.normalize_name(name)
    raise Mastodon::ValidationError, I18n.t('filters.errors.invalid_hashtag') if normalized.blank?

    duration = normalize_duration(expires_in)
    upsert_with_retry(account, normalized, duration, name)
  end

  private

  def upsert_with_retry(account, normalized, duration, raw_name)
    attempt = 0

    begin
      attempt += 1
      upsert!(account, normalized, duration, raw_name)
    rescue ActiveRecord::RecordNotUnique
      retry if attempt < 2

      raise
    end
  end

  def upsert!(account, normalized, duration, raw_name)
    ApplicationRecord.transaction do
      rule = CustomFilterTag.find_by(account_id: account.id, name: normalized)

      filter = if rule
                 rule.custom_filter.tap do |existing|
                   raise ActiveRecord::RecordNotFound if existing.nil? || existing.account_id != account.id

                   existing.expires_in = duration
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
