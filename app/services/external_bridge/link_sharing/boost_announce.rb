# frozen_string_literal: true

module ExternalBridge
  module LinkSharing
    # Hands one wrapper's Announce to ActivityPub distribution, only after the
    # reference note's Create has been distributed, and only under the consent
    # the boost was made under.
    #
    # Two transactions, one verification function.
    #
    # 1. Intent. Locks the policy row FOR SHARE, then the boost row FOR UPDATE,
    #    verifies, and commits announced_at. From here an Undo is owed if the
    #    row ends, because a distribution may follow. No Redis write happens
    #    in this transaction.
    # 2. Delivery. Locks the policy row FOR SHARE and the boost row FOR UPDATE
    #    again, verifies again, enqueues ActivityPub::DistributionWorker, and
    #    writes announce_enqueued_at. The two locks are held across the Redis
    #    call. Policy.revoke!, change_visibility! and grant! take the policy
    #    row FOR UPDATE, so each of them either commits before step 2 reads the
    #    policy (and step 2 sends nothing) or waits until step 2 has finished.
    #
    # The enqueue is the linearization point. A revocation that committed
    # before step 2 read the policy stops the Announce. A revocation that
    # arrives after the job was accepted does not recall it; the share is then
    # an announced share and only Undo ends it. The job that step 2 enqueues
    # is legitimate whatever happens to step 2's own transaction, because the
    # intent it depends on was committed by step 1. If step 2 fails after the
    # enqueue (a failed UPDATE or COMMIT, a crash), announce_enqueued_at stays
    # null and the scan enqueues again. That is a duplicate job for the same
    # activity: the Announce id is the wrapper's activity URI, which does not
    # change, so a receiver sees one activity id twice. Whether a receiver
    # drops the second delivery is the receiver's behaviour and is not
    # guaranteed here. An Announce job that is lost (nil jid, Redis error,
    # crash before the enqueue) is recovered the same way, from announced_at
    # set and announce_enqueued_at null.
    #
    # Lock order is policy, then boost. Boost takes policy, mapping, boost
    # rows; Unboost takes boost rows only; neither takes a lock this class
    # holds in the other direction.
    #
    # Scope of the serialization. The policy row is serialized with revoke,
    # grant, and scope changes. The feature flag and the tester list are
    # settings read without a row lock (and through the settings cache), so a
    # change that lands inside the few statements between the check and the
    # enqueue may not stop that one request; a change committed before the
    # check does. A User's Undo (Unboost) locks the boost row, so it either
    # ends the row before step 2 (nothing is enqueued) or waits for step 2 and
    # then sends the Undo.
    #
    # Other rules: Create first (while published_at is null nothing is done and
    # the publish worker pushes the pending boosts); the policy revision must
    # equal the revision stored on the row; a change of the flag or the tester
    # list after the row was created closes it; a closed row has its wrapper
    # removed without an Announce; local timelines are not touched.
    class BoostAnnounce
      def self.call(boost_id)
        new(boost_id).call
      end

      def initialize(boost_id)
        @boost_id = boost_id
      end

      def call
        boost = ExternalProjectionLinkBoost.find_by(id: @boost_id)
        return :gone if boost.nil?

        outcome = guarded(boost.user_id) { |locked, policy, removals| intend(locked, policy, removals) }
        return outcome unless outcome == :intended

        Checkpoints.fire(:announce_between_phases, boost.id)
        guarded(boost.user_id) { |locked, policy, removals| deliver(locked, policy, removals) }
      end

      private

      # Policy FOR SHARE, then boost FOR UPDATE. A row closed inside the block
      # hands back the wrapper ids that need RemovalWorker; they are enqueued
      # after the transaction.
      def guarded(user_id)
        removals = []
        outcome = ApplicationRecord.transaction do
          policy = ExternalLinkSharePolicy.lock('FOR SHARE').find_by(user_id: user_id)
          boost = ExternalProjectionLinkBoost.lock('FOR UPDATE').find_by(id: @boost_id)
          next :gone if boost.nil?
          next :ended unless boost.active?
          next :announced if boost.announce_enqueued?

          yield(boost, policy, removals)
        end
        Retire.enqueue_removals(removals)
        outcome
      end

      def intend(boost, policy, removals)
        verdict = verdict_for(boost, policy)
        return close(boost, verdict, removals) if verdict.is_a?(String)
        return verdict if verdict == :waiting

        boost.update!(announced_at: Time.current) unless boost.announced?
        Checkpoints.fire(:announce_intent_before_commit, boost.id)
        :intended
      end

      def deliver(boost, policy, removals)
        verdict = verdict_for(boost, policy)
        return close(boost, verdict, removals) if verdict.is_a?(String)
        return verdict if verdict == :waiting

        jid = enqueue_distribution(boost)
        return release_claim(boost) if jid.blank?

        Checkpoints.fire(:announce_after_enqueue, boost.id)
        boost.update!(announce_enqueued_at: Time.current)
        :announced
      end

      def close(boost, reason, removals)
        id = Retire.end!(boost, reason: reason)
        removals << id if id
        :closed
      end

      # Nothing was accepted. Leave announced_at (the intent) and make the row
      # selectable by the scan on its next pass instead of after the claim.
      def release_claim(boost)
        boost.update_columns(next_announce_at: Arel.sql('NOW()'))
        :enqueue_failed
      end

      def enqueue_distribution(boost)
        ActivityPub::DistributionWorker.perform_async(boost.wrapper_status_id)
      rescue Redis::BaseError => e
        Rails.logger.warn("[LinkSharing] announce enqueue failed boost_id=#{boost.id} error=#{e.class}")
        nil
      end

      # A String is the reason to close the row, :waiting means the Create is
      # not out yet, :go means the Announce may proceed.
      def verdict_for(boost, policy)
        mapping = ExternalProjectionLinkReference.find_by(id: boost.link_reference_id)
        reason = closing_reason(boost, mapping, policy)
        return reason if reason

        mapping.published_at.nil? ? :waiting : :go
      end

      def closing_reason(boost, mapping, policy)
        wrapper = Status.find_by(id: boost.wrapper_status_id)
        return 'wrapper_removed' if wrapper.nil?
        return 'projection_gone' unless marker_holds?(boost)
        return 'reference_unavailable' unless mapping_holds?(boost, mapping)
        return 'consent_withdrawn' unless consent_holds?(boost, policy)
        return 'feature_changed' if feature_changed_since?(boost)

        begin
          ReferenceIntegrity.verify!(mapping, mapping.reference_status)
        rescue Error
          return 'reference_modified'
        end

        nil
      end

      def marker_holds?(boost)
        return false if boost.external_status_projection_id.nil?

        marker = ExternalStatusProjection.find_by(id: boost.external_status_projection_id, user_id: boost.user_id, status_id: boost.projection_status_id)
        return false if marker.nil?

        # Held FOR SHARE until this transaction ends (it spans the enqueue), so
        # an unsubscribe is accepted either after the Announce was handed over
        # (the purge then owes an Undo) or before it (the row closes here).
        Ownership.lock_live_subscription!(marker)

        Ownership.assert_canonical!(User.find(boost.user_id), marker)
        true
      rescue Error, ActiveRecord::RecordNotFound
        false
      end

      def feature_changed_since?(boost)
        Setting.where(var: %w(external_bridge_link_sharing external_bridge_link_sharing_testers))
               .where('updated_at > ?', boost.created_at)
               .exists?
      end

      def mapping_holds?(boost, mapping)
        mapping.present? &&
          mapping.active? &&
          mapping.user_id == boost.user_id &&
          mapping.reference_status_id.present? &&
          mapping.reference_status_id == boost.reference_status_id &&
          current_canonical?(boost, mapping)
      end

      # The note still names the URL the projection has now. A changed URL
      # makes the mapping superseded at the next ensure; an Announce must not
      # wait for that.
      def current_canonical?(boost, mapping)
        marker = ExternalStatusProjection.find_by(id: boost.external_status_projection_id)
        marker.present? && NoteText.canonical_url!(marker.external_resource) == mapping.canonical_url
      rescue Error
        false
      end

      # policy is the row read under the FOR SHARE lock taken by guarded.
      def consent_holds?(boost, policy)
        user = User.find_by(id: boost.user_id)
        return false if user.nil? || !Feature.permitted?(user) || !user.functional?

        policy.present? && policy.enabled? && policy.consented_at.present? &&
          policy.visibility == boost.visibility && policy.revision == boost.policy_revision
      end
    end
  end
end
