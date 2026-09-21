# frozen_string_literal: true

# Enqueues overwrite-mode unfollows for accounts absent from the import.
# Follow additions stay on the batch executor. Callers must invoke this
# only after the batch is allowed to execute.
module FollowImport
  class OverwriteRemovalEnqueue
    def call(account:, csv_rows:)
      local_suffix = "@#{Rails.configuration.x.local_domain}"
      import_accts = Array(csv_rows).map { |row| address_for(row, local_suffix) }.compact.to_set

      account.following.find_each do |followee|
        next if import_accts.include?(followee.acct)

        Import::RelationshipWorker.perform_async(account.id, followee.acct, 'unfollow', {})
      end
    end

    private

    def address_for(row, local_suffix)
      row['Account address']&.strip&.delete_suffix(local_suffix).presence
    end
  end
end
