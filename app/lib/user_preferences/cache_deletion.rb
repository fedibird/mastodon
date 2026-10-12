# frozen_string_literal: true

class UserPreferences::CacheDeletion
  def initialize(user, keys)
    @user = user
    @keys = keys.dup.freeze
    @cache_deleted = {}
  end

  attr_reader :cache_deleted

  def before_committed!; end

  def committed!(should_run_callbacks: true)
    return unless should_run_callbacks

    @keys.each do |key|
      @cache_deleted[key] = delete_cache(key)
    end
  end

  def rolledback!(force_restore_state: false, should_run_callbacks: true); end

  def trigger_transactional_callbacks?
    true
  end

  private

  def delete_cache(key)
    attempts = 0
    begin
      attempts += 1
      Rails.cache.delete(Setting.cache_key(key, @user))
      true
    rescue StandardError => error
      log_failure(key, error, attempts)
      retry if attempts < 3

      false
    end
  end

  def log_failure(key, error, attempts)
    line = "UserPreferences cache delete failed user_id=#{@user.id} var=#{key} error=#{error.class}: #{error.message}"
    if attempts < 3
      Rails.logger.warn(line)
    else
      Rails.logger.error(line)
    end
  end
end
