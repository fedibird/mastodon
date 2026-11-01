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

  def to_param
    var
  end

  # Group invite defaults are the only rows that re-read under a lock.
  # Every other setting keeps RailsSettings' own after_commit write.
  # The lock is transaction-scoped: PgBouncer transaction pooling can send
  # a later unlock to a different backend, so there is no session lock.
  def rewrite_cache
    if GroupRegistrationInvites::UpdateSiteDefaults::KEYS.include?(var)
      refresh_group_invite_default_cache
    else
      super
    end
  end

  def refresh_group_invite_default_cache
    lock_key = GroupRegistrationInvites::UpdateSiteDefaults::LOCK_KEY
    self.class.transaction do
      self.class.connection.execute("SELECT pg_advisory_xact_lock(#{lock_key})")
      current = self.class.unscoped.find_by(id: id)
      if current && GroupRegistrationInvites::UpdateSiteDefaults::KEYS.include?(current.var)
        Rails.cache.write(current.cache_key, current.value)
      else
        expire_cache
      end
    end
  end
  private :refresh_group_invite_default_cache

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
