# frozen_string_literal: true
# == Schema Information
#
# Table name: settings
#
#  id         :bigint(8)        not null, primary key
#  var        :string           not null
#  value      :text
#  thing_type :string
#  created_at :datetime
#  updated_at :datetime
#  thing_id   :bigint(8)
#

class Setting < RailsSettings::Base
  source Rails.root.join('config', 'settings.yml')

  # Shared with GroupRegistrationInvites::UpdateSiteDefaults. The transaction
  # lock and this cache refresh use one advisory-lock key, so a refresh
  # cannot publish a row that a writer has not committed yet.
  CACHE_LOCK_KEY = 6_740_002_002

  def to_param
    var
  end

  # The saved instance can be older than the committed row by the time this
  # runs: commit releases the transaction lock before after_commit. Read the
  # row again while holding the lock so a newer commit is what gets cached.
  def rewrite_cache
    connection = self.class.connection
    connection.execute("SELECT pg_advisory_lock(#{CACHE_LOCK_KEY})")
    current = self.class.unscoped.find_by(id: id)
    if current
      Rails.cache.write(cache_key, current.value)
    else
      expire_cache
    end
  ensure
    connection&.execute("SELECT pg_advisory_unlock(#{CACHE_LOCK_KEY})")
  end

  class << self
    def [](key)
      return super(key) unless rails_initialized?

      val = Rails.cache.fetch(cache_key(key, nil)) do
        db_val = object(key)

        if db_val
          default_value = default_settings[key]

          return default_value.with_indifferent_access.merge!(db_val.value) if default_value.is_a?(Hash)
          db_val.value
        else
          default_settings[key]
        end
      end
      val
    end

    def all_as_records
      vars    = thing_scoped
      records = vars.index_by(&:var)

      default_settings.each do |key, default_value|
        next if records.key?(key) || default_value.is_a?(Hash)
        records[key] = Setting.new(var: key, value: default_value)
      end

      records
    end

    def default_settings
      return {} unless RailsSettings::Default.enabled?
      RailsSettings::Default.instance
    end
  end
end
