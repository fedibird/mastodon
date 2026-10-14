# frozen_string_literal: true

class UserPreferences::CacheDeletion
  def initialize(user, keys, revision:)
    @user = user
    @keys = keys.dup.freeze
    @revision = revision
    @cache_deleted = {}
    @revision_cache_deleted = {}
  end

  # Legacy-key results only, keyed by preference var.
  # true means Rails.cache.delete returned true.
  # false means the delete returned false, or the exception retries were exhausted.
  # Those two false cases are separate in the logs: only exceptions are warned.
  attr_reader :cache_deleted, :revision_cache_deleted

  def before_committed!; end

  def committed!(should_run_callbacks: true)
    return unless should_run_callbacks

    @keys.each do |key|
      @cache_deleted[key] = delete_cache(Setting.cache_key(key, @user), key, :legacy)
      @revision_cache_deleted[key] = delete_cache(UserPreferences::CacheKey.for_revision(key, @user, @revision), key, :revision)
    end
  end

  def rolledback!(force_restore_state: false, should_run_callbacks: true); end

  def trigger_transactional_callbacks?
    true
  end

  private

  def delete_cache(cache_key, var, generation)
    attempts = 0
    begin
      attempts += 1
      Rails.cache.delete(cache_key) == true
    rescue StandardError => e
      log_failure(var, generation, e, attempts)
      retry if attempts < 3

      false
    end
  end

  def log_failure(var, generation, error, attempts)
    revision_note = generation == :revision ? " revision=#{@revision}" : ''
    line = "UserPreferences cache delete failed user_id=#{@user.id} var=#{var} generation=#{generation}#{revision_note} error=#{error.class}"
    if attempts < 3
      Rails.logger.warn(line)
    else
      Rails.logger.error(line)
    end
  end
end
