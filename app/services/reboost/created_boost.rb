# frozen_string_literal: true

# Links a committed boost to its operation before Redis or a queue write.
# A crash between those steps resumes the same wrapper.
module Reboost::CreatedBoost
  private

  # A second stamp would start the five minutes over after a crash.
  def stamp_cooldown_once!
    return if ReboostCooldown.remaining_seconds(account.id, original.id).positive?

    ReboostCooldown.stamp!(account.id, original.id)
  end

  def attach_created!(created, existing)
    return unless resumed_operation || ordered_undo? || existing&.local?

    federation_operation(created, existing&.local? ? existing : nil)
  end

  # Queues run only after the operation points at this wrapper.
  def publish_created!(created, existing)
    operation = federation_record_for(created)
    distribute_locally!(created, federate: existing.nil? && !ordered_undo? && operation.nil?, operation: operation)
    return if operation.nil?

    enqueue_federation!(operation)
    Reboost::Log.emit('federation_scheduled', operation_id: operation.id, gap_seconds: Reboost::FEDERATION_GAP.to_i)
  end

  def federation_record_for(created)
    operation = @recovery || resumed_operation
    operation if operation&.new_status_id == created.id && operation.state == 'federating'
  end

  # Status, the decided audience, the cooldown, and the operation link commit
  # together. A raise before that commit leaves no wrapper to deliver.
  def commit_created_boost!(visibility, audience, existing)
    decided = Reboost::RecoveryRecord.audience_for(audience, resumed_operation&.options, @resolved_circle, existing, options)
    created = nil
    ApplicationRecord.transaction do
      created = account.statuses.create!(reblog: original, text: '', visibility: visibility, rate_limit: options[:with_rate_limit])
      created.capability_tokens.create! if created.limited_visibility?
      after_status_record!(created)
      Array(decided).each do |account_id, silent|
        save_decided_mention!(created.mentions.new(account_id: account_id, silent: silent == true))
      end
      before_operation_link!(created)
      stamp_cooldown_once!
      attach_created!(created, existing)
    end
    created
  end

  def after_status_record!(_created); end

  def save_decided_mention!(mention)
    mention.save!
  end

  def before_operation_link!(_created); end

  # The wrapper committed and the process stopped before the operation link.
  def resume_unlinked_wrapper!
    operation = resumed_operation
    return if operation.nil?

    operation.reload
    return unless operation.state == 'pending'

    created = account.statuses.where(reblog_of_id: original.id).where.not(id: operation.old_status_id).order(:id).last
    return if created.nil?
    unless audience_complete?(created, operation)
      RemoveStatusService.new.call(created, skip_remote: true, immediate: true)
      return
    end

    stamp_cooldown_once!
    attach_created!(created, nil)
    remember_idempotency!(created)
    publish_created!(created, nil)
    created
  end

  def audience_complete?(created, operation)
    expected = operation.options.is_a?(Hash) ? operation.options['audience'] : nil
    return false unless expected.is_a?(Array)

    actual = created.mentions.pluck(:account_id, :silent).map { |account_id, silent| [account_id.to_i, silent == true] }
    expected_pairs = expected.map { |account_id, silent| [account_id.to_i, silent == true] }
    actual.sort == expected_pairs.sort
  end
end
