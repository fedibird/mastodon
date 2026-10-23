# frozen_string_literal: true

module ExternalBridge
  module LinkSharing
    # Gets or creates one reference Status for a user, projection, scope, and
    # canonical URL. The projection row is not updated. public and unlisted
    # are never substituted for each other.
    #
    # Lock order: external_link_share_policies FOR UPDATE, then the matching
    # external_projection_link_references rows FOR UPDATE, then the new
    # Status, then the mapping insert. Policy updates lock only the policy
    # row, so they cannot deadlock with this order. A revocation that commits
    # before the policy lock is observed and writes nothing. A revocation that
    # arrives while this transaction holds the lock waits, and the note from
    # the revision we held is kept.
    class EnsureReference
      VISIBILITIES = %w(public unlisted).freeze
      ATTEMPTS = 3
      Result = Struct.new(:status, :mapping, :created, keyword_init: true)

      def self.call(user:, projection:, scope:)
        new(user, projection, scope).call
      end

      def initialize(user, projection, scope)
        @user = user
        @projection = projection
        @scope = scope.to_s
      end

      def call
        raise Error, :not_owner if @user.nil? || @projection.nil?
        raise Error, :scope_rejected unless VISIBILITIES.include?(@scope)

        Feature.require!(@user)
        Ownership.assert!(@user, @projection)

        ATTEMPTS.times do
          outcome = run_attempt
          if outcome == :conflict
            found = committed_reusable(current_canonical)
            return finish(found, created: false) if found

            next
          end
          next if outcome == :retry

          return finish(outcome.mapping, created: outcome.created)
        end

        raise Error, :reference_conflict
      end

      private

      def run_attempt
        ApplicationRecord.transaction(requires_new: true) { attempt }
      rescue ActiveRecord::RecordNotUnique
        :conflict
      rescue Error => e
        raise unless e.code == 'canonical_url_changed'

        :retry
      end

      def attempt
        policy = ExternalLinkSharePolicy.lock('FOR UPDATE').find_by(user_id: @user.id)
        assert_policy!(policy)
        snapshot = policy.revision
        Checkpoints.fire(:after_policy_lock)
        assert_policy_snapshot!(policy, snapshot)

        canonical = current_canonical
        rows = locked_rows
        reusable = pick_reusable(rows, canonical)
        return Result.new(mapping: reusable, created: false) if reusable
        raise Error, :source_deleted if @projection.source_deleted

        supersede_other_urls!(rows, canonical)
        Checkpoints.fire(:before_status_create)
        assert_policy_snapshot!(policy, snapshot)
        raise Error, :canonical_url_changed if current_canonical != canonical

        text = composed_text(canonical)
        reject_leaks!(text, canonical)
        reject_orphan!(text)
        status = create_status!(text)
        Checkpoints.fire(:before_mapping_insert, status.id)
        assert_policy_snapshot!(policy, snapshot)
        raise Error, :canonical_url_changed if current_canonical != canonical

        mapping = insert_mapping!(status, canonical, policy.revision)
        Result.new(mapping: mapping, created: true)
      end

      def assert_policy!(policy)
        raise Error, :consent_required if policy.nil? || !policy.enabled? || policy.consented_at.nil?
        raise Error, :scope_rejected unless policy.visibility == @scope
      end

      def assert_policy_snapshot!(policy, snapshot)
        policy.reload
        assert_policy!(policy)
        raise Error, :policy_changed unless policy.revision == snapshot
      end

      def current_canonical
        NoteText.canonical_url!(@projection.external_resource.reload)
      end

      def locked_rows
        ExternalProjectionLinkReference.lock('FOR UPDATE').where(
          user_id: @user.id,
          external_status_projection_id: @projection.id,
          visibility: @scope
        ).to_a
      end

      def pick_reusable(rows, canonical)
        same = rows.select { |row| row.canonical_url == canonical }
        if same.any? { |row| row.broken? || (row.active? && !healthy?(row)) }
          same.each { |row| mark_broken!(row) if row.active? }
          raise Error, :reference_broken
        end

        active = same.find { |row| row.active? && healthy?(row) }
        return active if active

        other = rows.find { |row| row.active? && row.canonical_url != canonical }
        if other && !healthy?(other)
          mark_broken!(other)
          raise Error, :reference_broken
        end

        nil
      end

      def supersede_other_urls!(rows, canonical)
        rows.each do |row|
          next unless row.active? && row.canonical_url != canonical && healthy?(row)

          row.update!(state: 'superseded', superseded_at: Time.current)
        end
      end

      def composed_text(canonical)
        NoteText.compose(source: @projection.external_resource.external_source, canonical_url: canonical)
      end

      def reject_leaks!(text, canonical)
        forbidden_fragments.each do |fragment|
          value = fragment.to_s
          next if value.length < 8
          next if allowed_fragment?(value, canonical)

          raise Error, :reference_text_rejected if text.include?(value)
        end
      end

      def allowed_fragment?(value, canonical)
        source = @projection.external_resource.external_source
        title = NoteText.sanitize_title(source&.title)
        [canonical, title, 'RSS', 'Atom'].include?(value)
      end

      def forbidden_fragments
        resource = @projection.external_resource
        status = @projection.status
        fragments = [resource.body, resource.byline, resource.title, status.text, status.spoiler_text]
        fragments.concat(MediaAttachment.where(status_id: status.id).pluck(:description))
        poll = Poll.find_by(status_id: status.id)
        fragments.concat(Array(poll.options)) if poll
        fragments
      end

      def reject_orphan!(text)
        orphan = Status.unscoped.where(
          account_id: @user.account_id,
          text: text,
          deleted_at: nil
        ).where.not(id: @projection.status_id).where('external_projection IS NOT TRUE').first
        return if orphan.nil?
        return if ExternalProjectionLinkReference.exists?(reference_status_id: orphan.id)

        raise Error, :reference_broken
      end

      def create_status!(text)
        Status.create!(
          account_id: @user.account_id,
          text: text,
          visibility: @scope,
          searchability: @scope,
          sensitive: false,
          spoiler_text: '',
          local: true,
          reply: false,
          external_projection: false
        )
      end

      def insert_mapping!(status, canonical, policy_revision)
        ExternalProjectionLinkReference.create!(
          user_id: @user.id,
          account_id: @user.account_id,
          external_status_projection_id: @projection.id,
          projection_status_id: @projection.status_id,
          reference_status_id: status.id,
          visibility: @scope,
          canonical_url: canonical,
          resource_revision: @projection.external_resource.revision,
          policy_revision: policy_revision,
          state: 'active'
        )
      end

      def healthy?(row)
        status = row.reference_status
        status.present? &&
          status.deleted_at.nil? &&
          status.external_projection != true &&
          status.account_id == @user.account_id
      end

      def mark_broken!(row)
        return if row.broken?

        row.update!(state: 'broken')
      end

      def committed_reusable(canonical)
        row = ExternalProjectionLinkReference.find_by(
          user_id: @user.id,
          external_status_projection_id: @projection.id,
          visibility: @scope,
          canonical_url: canonical,
          state: 'active'
        )
        return nil if row.nil? || !healthy?(row)

        row
      end

      def finish(mapping, created:)
        status = mapping.reference_status
        PublishStatusService.new.call(status) unless PublishStatusService.new.published?(status)
        Result.new(status: status.reload, mapping: mapping.reload, created: created)
      end
    end
  end
end
