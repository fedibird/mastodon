# frozen_string_literal: true

class UserPreferences::Writer
  ATTEMPTS = 3

  def initialize(user)
    raise ArgumentError, 'user is required' unless user.is_a?(User) && user.id.present?

    @user = user
    @contract = UserPreferences::WriteContract.new
  end

  def apply(updates: nil, resets: nil)
    refuse_open_transaction!
    request = @contract.validate!(updates: updates.nil? ? {} : updates, resets: resets.nil? ? [] : resets)
    return empty_result if request.empty?

    attempt = 0
    begin
      attempt += 1
      write_once(request)
    rescue ActiveRecord::RecordNotUnique
      raise UserPreferences::Conflict if attempt >= ATTEMPTS

      retry
    end
  end

  private

  def refuse_open_transaction!
    raise UserPreferences::OpenTransaction if User.connection.transaction_open?
  end

  def empty_result
    revision = UserPreferences::Revision.current(@user.id)
    UserPreferences::WriteResult.new(
      before: {},
      after: {},
      changed_keys: [],
      unchanged_keys: [],
      cache_deleted: {},
      before_revision: revision,
      after_revision: revision
    )
  end

  def write_once(request)
    callback = nil
    change_set = nil
    before_revision = nil
    after_revision = nil
    User.transaction do
      locked = lock_user
      before_revision = UserPreferences::Revision.current_for_update(locked.id)
      change_set = UserPreferences::ChangeSet.build(read_stored(locked, request), request)
      change_set.writes.each { |operation| persist(locked.id, operation) }
      after_revision = if change_set.changed_keys.any?
                         UserPreferences::Revision.advance!(locked.id)
                       else
                         before_revision
                       end
      callback = register_after_commit(locked, change_set, after_revision)
    end
    UserPreferences::WriteResult.new(
      before: change_set.before,
      after: change_set.after,
      changed_keys: change_set.changed_keys,
      unchanged_keys: change_set.unchanged_keys,
      cache_deleted: callback ? callback.cache_deleted : {},
      before_revision: before_revision,
      after_revision: after_revision
    )
  end

  # Cache deletion and the change notification run after COMMIT.
  # Each one swallows its own failure so the other still runs.
  def register_after_commit(locked, change_set, after_revision)
    return unless change_set.changed_keys.any?

    deletion = UserPreferences::CacheDeletion.new(locked, change_set.changed_keys)
    User.connection.add_transaction_record(deletion)
    User.connection.add_transaction_record(
      UserPreferences::ChangeNotification.new(
        user_id: locked.id,
        account_id: locked.account_id,
        changed_keys: change_set.changed_keys,
        revision: after_revision
      )
    )
    deletion
  end

  def lock_user
    User.lock.find(@user.id)
  end

  def read_stored(locked, request)
    reader = UserPreferences::Reader.new(locked)
    request.keys.index_with do |key|
      value = reader.get(key)
      { state: value.state, configured: value.configured }
    end
  end

  def persist(user_id, operation)
    case operation.action
    when :set
      if operation.insert
        insert_row(user_id, operation.key, operation.value)
      else
        update_row(user_id, operation.key, operation.value)
      end
    when :delete
      delete_row(user_id, operation.key)
    end
  end

  def insert_row(user_id, key, value)
    record = Setting.unscoped.new(thing_type: 'User', thing_id: user_id, var: key)
    record.value = value
    record.save!
  end

  def update_row(user_id, key, value)
    record = Setting.unscoped.find_by!(thing_type: 'User', thing_id: user_id, var: key)
    record.value = value
    record.save!
  end

  def delete_row(user_id, key)
    Setting.unscoped.where(thing_type: 'User', thing_id: user_id, var: key).delete_all
  end
end
