# frozen_string_literal: true

module GroupRoles
  # Two-party, time-bounded owner transfer. Each mutation locks ManagedGroup
  # first, then the offer and assignments, to serialize against role changes.
  class OwnerTransfers
    OFFER_LIFETIME = 7.days

    def self.offer(managed_group:, actor_account:, candidate_account:)
      return :not_authorized unless GroupManagement.local_functional_person?(actor_account)

      ManagedGroup.transaction do
        managed = ManagedGroup.lock.find(managed_group.id)
        next :not_authorized unless current_owner?(managed, actor_account)
        next :invalid_target unless GroupManagement.local_functional_person?(candidate_account)
        next :invalid_target if candidate_account.id == actor_account.id

        existing = GroupOwnerTransferOffer.pending.lock.find_by(group_account_id: managed.account_id)
        if existing && existing.candidate_account_id == candidate_account.id && !existing.expired?
          next :already_pending
        end

        existing&.update!(state: :cancelled, responded_at: Time.current)
        offer = GroupOwnerTransferOffer.create!(
          group_account_id: managed.account_id,
          offered_by_account: actor_account,
          candidate_account: candidate_account,
          expires_at: Time.current + OFFER_LIFETIME
        )
        audit!(actor_account, :offer_group_ownership, managed, offer)
        :offered
      end
    rescue ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::StaleObjectError
      :conflict
    rescue GroupAdministration::Audit::Error
      :audit_failed
    end

    def self.cancel(offer:, actor_account:)
      return :not_authorized unless GroupManagement.local_functional_person?(actor_account)

      ManagedGroup.transaction do
        managed = ManagedGroup.lock.find_by!(account_id: offer.group_account_id)
        pending = GroupOwnerTransferOffer.lock.find(offer.id)
        next :not_authorized unless current_owner?(managed, actor_account) && pending.offered_by_account_id == actor_account.id
        next :not_pending unless pending.pending?

        pending.update!(state: :cancelled, responded_at: Time.current)
        audit!(actor_account, :cancel_group_ownership_offer, managed, pending)
        :cancelled
      end
    rescue ActiveRecord::RecordNotFound
      :not_pending
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::StaleObjectError
      :conflict
    rescue GroupAdministration::Audit::Error
      :audit_failed
    end

    def self.accept(offer:, actor_account:)
      return :not_authorized unless GroupManagement.local_functional_person?(actor_account)
      return :not_authorized unless offer.candidate_account_id == actor_account.id

      ManagedGroup.transaction do
        managed = ManagedGroup.lock.find_by!(account_id: offer.group_account_id)
        pending = GroupOwnerTransferOffer.lock.find(offer.id)
        next :not_pending unless pending.pending?
        next :expired if pending.expired?
        next :stale_owner unless current_owner?(managed, pending.offered_by_account)
        next :invalid_target unless GroupManagement.local_functional_person?(pending.candidate_account)

        # One account cannot hold an active moderator and owner role together.
        # Revoke the moderator inside the same transaction as the transfer.
        moderator = GroupRoleAssignment.active.moderator.find_by(
          group_account_id: managed.account_id, member_account_id: actor_account.id
        )
        timestamp = Time.current
        moderator&.revoke!(revoked_at: timestamp)
        GroupRoleAssignment.transfer_owner!(
          group_account: managed.account,
          member_account: actor_account,
          granted_by_account: pending.offered_by_account,
          transferred_at: timestamp
        )
        pending.update!(state: :accepted, responded_at: timestamp)
        audit!(actor_account, :accept_group_ownership, managed, pending)
        :accepted
      end
    rescue ActiveRecord::RecordNotFound
      :not_pending
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::StaleObjectError
      :conflict
    rescue GroupAdministration::Audit::Error
      :audit_failed
    end

    def self.current_owner?(managed, account)
      return false unless managed.approved_request? && managed.creation_request&.approved?
      return false unless GroupManagement.local_functional_person?(account)

      GroupRoleAssignment.active.owner.where(group_account_id: managed.account_id, member_account_id: account.id).exists?
    end
    private_class_method :current_owner?

    def self.audit!(actor, action, managed, offer)
      GroupAdministration::Audit.record!(
        account: actor,
        action: action,
        target: managed,
        changes: {
          'offer_id' => offer.id,
          'offered_by_account_id' => offer.offered_by_account_id,
          'candidate_account_id' => offer.candidate_account_id,
        }
      )
    end
    private_class_method :audit!
  end
end
