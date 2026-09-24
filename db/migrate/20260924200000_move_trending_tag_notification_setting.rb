# frozen_string_literal: true

# Copies user notification_emails.trending_tag onto notification_emails.trends
# and drops the old key. A stored false must stay false. An existing trends
# value wins. Rows with neither key are left untouched so the new default applies.
class MoveTrendingTagNotificationSetting < ActiveRecord::Migration[6.1]
  class SettingRecord < ActiveRecord::Base
    self.table_name = 'settings'
  end

  def up
    rewrite('trending_tag', 'trends')
  end

  def down
    rewrite('trends', 'trending_tag')
  end

  private

  def rewrite(from_key, to_key)
    SettingRecord.where(thing_type: 'User', var: 'notification_emails').find_each do |record|
      original = YAML.unsafe_load(record.value) if record.value.present?
      next unless original.is_a?(Hash)

      updated = original.each_with_object({}) { |(key, value), hash| hash[key.to_s] = value }
      updated[to_key] = updated[from_key] if updated.key?(from_key) && !updated.key?(to_key)
      updated.delete(from_key)
      next if updated == stringify_keys(original)

      record.update_columns(value: updated.to_yaml, updated_at: Time.now.utc)
    end
  end

  def stringify_keys(hash)
    hash.each_with_object({}) { |(key, value), converted| converted[key.to_s] = value }
  end
end
