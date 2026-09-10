# frozen_string_literal: true

class ActivityPub::Activity::Block < ActivityPub::Activity
  def perform
    target_account = account_from_uri(object_uri)

    return if target_account.nil? || !target_account.local?

    if @account.blocking?(target_account)
      existing_block = @account.block_relationships.find_by(target_account: target_account)
      existing_block.update(uri: @json['id']) if existing_block && @json['id'].present?
      record_inbound_block(target_account, existing_block)
      return
    end

    UnfollowService.new.call(@account, target_account) if @account.following?(target_account)
    UnfollowService.new.call(target_account, @account) if target_account.following?(@account)
    RejectFollowService.new.call(target_account, @account) if target_account.requested?(@account)
    UnsubscribeAccountService.new.call(target_account, @account, list_id: :all)

    unless delete_arrived_first?(@json['id'])
      BlockWorker.perform_async(@account.id, target_account.id)
      block = @account.block!(target_account, uri: @json['id'])

      record_inbound_block(target_account, block)
    end
  end

  private

  # Inbound block of a local account: the remote actor rejected the local
  # account. Idempotent via source_event_key (the Block record), so re-delivery
  # both dedupes and repairs a ledger event a transient recorder failure missed.
  def record_inbound_block(target_account, block)
    return if block.nil?

    Moderation::EventRecorder.record_rejection(rejector: @account, rejected: target_account, event_type: :block, source_record: block)
  end
end
