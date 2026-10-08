# frozen_string_literal: true

class UserPostingContext
  # User-owned tags are always advisory. Required tags belong to a destination
  # discovery result and are not stored in this column.
  class ManagedHashtags
    MAX_COUNT = 20
    MAX_TEXT = 2_000
    KEYS = %w(name normalized_name enforcement rule_id).freeze

    def self.form_text(managed)
      list = hash_value(managed, 'hashtags')
      Array(list).map { |tag| hash_value(tag, 'name') }.compact.join(' ')
    end

    def self.write(record)
      return unless record.submitted?('hashtags_text')

      text = record.hashtags_text.to_s
      if text.length > MAX_TEXT
        record.errors.add(:base, I18n.t('user_posting_contexts.errors.hashtag_list'))
        return
      end

      tags, invalid = parse_text(text)
      if invalid || tags.length > MAX_COUNT
        record.errors.add(:base, I18n.t('user_posting_contexts.errors.hashtag_list'))
        return
      end

      record.managed = { 'hashtags' => tags }
    end

    def self.validate_stored(record)
      managed = record.managed
      return record.errors.add(:base, I18n.t('user_posting_contexts.errors.managed')) unless managed.is_a?(Hash)

      data = managed.deep_stringify_keys
      unknown = data.keys - ['hashtags']
      return record.errors.add(:base, I18n.t('user_posting_contexts.errors.managed')) if unknown.any?

      list = data['hashtags']
      return if list.nil?
      return record.errors.add(:base, I18n.t('user_posting_contexts.errors.managed')) unless list.is_a?(Array)
      return record.errors.add(:base, I18n.t('user_posting_contexts.errors.hashtag_list')) if list.length > MAX_COUNT

      seen = {}
      list.each do |tag|
        normalized = stored_tag_normalized_name(tag)
        return record.errors.add(:base, I18n.t('user_posting_contexts.errors.managed')) if normalized.nil? || seen[normalized]

        seen[normalized] = true
      end
    end

    def self.parse_text(text)
      tags = []
      invalid = false

      text.to_s.split(/[\s,，]+/).each do |token|
        next if token.blank?

        pair = HashtagName.canonicalize(token)
        if pair.nil?
          invalid = true
          next
        end

        display, normalized = pair
        next if tags.any? { |tag| tag['normalized_name'] == normalized }

        tags << {
          'name' => display,
          'normalized_name' => normalized,
          'enforcement' => 'advisory',
          'rule_id' => UserPostingContext::ADVISORY_HASHTAG_RULE_ID,
        }
      end

      [tags, invalid]
    end

    def self.stored_tag_normalized_name(tag)
      return unless tag.is_a?(Hash)

      data = tag.deep_stringify_keys
      return if data.keys.sort != KEYS.sort
      return unless data['enforcement'] == 'advisory'
      return unless data['rule_id'] == UserPostingContext::ADVISORY_HASHTAG_RULE_ID

      pair = HashtagName.canonicalize(data['name'])
      return if pair.nil?

      display, normalized = pair
      return unless display == data['name'] && normalized == data['normalized_name']

      normalized
    end

    def self.hash_value(hash, key)
      return unless hash.is_a?(Hash)

      hash[key] || hash[key.to_sym]
    end

    private_class_method :parse_text, :stored_tag_normalized_name, :hash_value
  end
end
