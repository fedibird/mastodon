# frozen_string_literal: true

# One in-flight replacement per account and original. A second key, or a
# plain boost, joins that operation instead of creating another wrapper.
class Reboost::OpenOperation
  def self.join!(account:, original_id:, resumed_operation_id:)
    open = ReboostOperation.open.where(account_id: account.id, reblog_of_id: original_id).order(id: :desc).first
    return if open.nil? || resumed_operation_id.to_s == open.id.to_s

    if open.state == 'federating'
      status = Status.find_by(id: open.new_status_id)
      return status if status

      # The wrapper is already gone, so this row is no longer an in-flight
      # replacement. Close it and let the cooldown decide the next boost.
      Reboost::Placement.fail_open!(open, 'missing_status')
      return
    end

    raise Mastodon::ReboostPendingError, open
  end

  def self.save!(operation)
    operation.save!
  rescue ActiveRecord::RecordNotUnique
    existing = ReboostOperation.open.find_by(account_id: operation.account_id, reblog_of_id: operation.reblog_of_id)
    raise Mastodon::ReboostPendingError, existing if existing

    raise
  end
end
