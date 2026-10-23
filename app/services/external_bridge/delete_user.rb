# frozen_string_literal: true

module ExternalBridge
  # Deletes one user without deleting the account. Projection statuses are
  # physically removed in the same transaction, then the user row. Another
  # user of the same account keeps their own projections. Direct
  # `User#destroy` and `DELETE FROM users` still fail while a marker remains.
  class DeleteUser
    def self.call(user)
      ApplicationRecord.transaction(requires_new: true) do
        ids = ExternalStatusProjection.where(user_id: user.id).pluck(:status_id)
        if ids.any?
          # The user row is removed in this transaction. Streaming would lose
          # its authorization, so this path does not emit delete events.
          ActiveRecord::Base.connection.execute(ProjectionPurge::SETTING_SQL)
          Status.unscoped.where(id: ids).delete_all
          ActiveRecord::Base.connection.execute("SET LOCAL fedibird.projection_status_delete = 'off'")
        end
        user.destroy!
      end
    end
  end
end
