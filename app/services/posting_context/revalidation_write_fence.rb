# frozen_string_literal: true

class PostingContext::RevalidationWriteFence
  # Holds a per-account advisory lock across the snapshot write and re-checks
  # the Redis lease only after that lock is taken. The lock lasts until the
  # write transaction ends, so an older request cannot commit after a newer
  # request has committed. Callers keep HTTP outside this block.
  def self.call(account_id, request_id)
    return yield if request_id.blank?

    result = nil
    kept = false

    Account.transaction do
      advisory_lock!(account_id)
      unless PostingContext::RevalidationRegistry.new.owns_lock?(account_id, request_id)
        raise ActiveRecord::Rollback
      end

      result = yield
      kept = true
    end

    kept ? result : nil
  end

  def self.advisory_lock!(account_id)
    sql = Account.sanitize_sql_array(
      [
        "SELECT pg_advisory_xact_lock(('x' || substr(md5(?), 1, 16))::bit(64)::bigint)",
        "posting_context:revalidation:#{account_id.to_i}",
      ]
    )
    Account.connection.execute(sql)
  end
  private_class_method :advisory_lock!
end
