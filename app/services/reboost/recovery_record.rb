# frozen_string_literal: true

# The visibility and audience chosen before the old boost is removed.
# A later resume reads this snapshot instead of the account default.
class Reboost::RecoveryRecord
  def self.save!(existing:, operation:, account:, original:, visibility:, circle:, audience:, options:, undo_payload:, undo_inboxes:) # rubocop:disable Metrics/ParameterLists
    attributes = {
      old_status_id: existing.id,
      state: 'pending',
      reboost: true,
      visibility: visibility,
      circle_id: circle.is_a?(Circle) ? circle.id : options[:circle_id],
      undo_payload: undo_payload,
      undo_inboxes: undo_inboxes,
      removal_started_at: Time.current,
      options: {
        'visibility_explicit' => options[:visibility_explicit] == true,
        'circle_explicit' => options[:circle_explicit] == true,
        'audience' => audience_for(audience, operation&.options, circle, existing),
      },
    }

    if operation && !operation.terminal?
      operation.update!(attributes)
      operation
    else
      ReboostOperation.create!(
        attributes.merge(
          account: account,
          reblog_of_id: original.id,
          idempotency_key: options[:idempotency]
        )
      )
    end
  end

  # A blank new list keeps a snapshot already stored on the operation.
  # An explicit circle whose members are not in that list is read once.
  def self.audience_for(audience, stored_options, circle, existing)
    stored = stored_options.is_a?(Hash) ? stored_options['audience'] : nil
    return pairs(audience) if audience.present?
    return stored if stored.is_a?(Array)

    pairs(circle_pairs(circle) || mention_pairs(existing))
  end

  def self.pairs(rows)
    Array(rows).map { |account_id, silent| [account_id, silent == true] }
  end

  def self.circle_pairs(circle)
    return if circle.nil?

    accounts = circle.instance_of?(Account) ? circle.mutuals : circle.accounts
    accounts.map { |target| [target.id, true] }
  end

  def self.mention_pairs(existing)
    existing.mentions.pluck(:account_id, :silent)
  end

  private_class_method :pairs, :circle_pairs, :mention_pairs
end
