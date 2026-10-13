# frozen_string_literal: true

# Publishes preferences_changed after Writer commits.
# Redis errors are logged and do not roll back the committed write.
class UserPreferences::ChangeNotification
  EVENT = 'preferences_changed'
  VERSION = 1

  def initialize(user_id:, account_id:, changed_keys:, revision:)
    @user_id = integer_id(user_id)
    @account_id = integer_id(account_id)
    @changed_keys = public_changed_keys(changed_keys)
    @revision = decimal_revision(revision)
    @publishable = true
  end

  attr_reader :user_id, :account_id, :changed_keys, :revision

  def channel
    "timeline:preferences:#{account_id}"
  end

  def before_committed!; end

  def committed!(should_run_callbacks: true)
    return unless should_run_callbacks && @publishable

    @publishable = false
    return if changed_keys.empty?

    publish
  end

  # Rails 6.1 always passes these keywords. A rolled-back attempt never publishes.
  def rolledback!(force_restore_state: false, should_run_callbacks: true) # rubocop:disable Lint/UnusedMethodArgument
    @publishable = false
  end

  def trigger_transactional_callbacks?
    true
  end

  private

  def integer_id(value)
    raise ArgumentError, 'id must be an integer' unless value.is_a?(Integer)

    value
  end

  def decimal_revision(value)
    raise ArgumentError, 'revision must be an integer' unless value.is_a?(Integer)

    format('%d', value)
  end

  def public_changed_keys(keys)
    return [].freeze unless keys.is_a?(Array)

    seen = {}
    keys.each_with_object([]) do |key, public_keys|
      next unless key.is_a?(String)
      next if seen[key]
      next unless UserPreferences::WriteContract::KEYS.include?(key)

      seen[key] = true
      public_keys << "user.#{key}"
    end.freeze
  end

  def publish
    if User.connection.transaction_open?
      log_failure('open_transaction')
      return
    end

    RedisConfiguration.with do |redis|
      redis.publish(channel, Oj.dump(envelope))
    end
  rescue StandardError => e
    log_failure(e.class.name)
  end

  def envelope
    {
      event: EVENT,
      payload: {
        version: VERSION,
        revision: revision,
        changed_keys: changed_keys,
      },
      queued_at: (Time.now.to_f * 1000.0).to_i,
    }
  end

  def log_failure(error_name)
    Rails.logger.error(
      "UserPreferences change notification failed user_id=#{user_id} account_id=#{account_id} revision=#{revision} error=#{error_name}"
    )
  end
end
