# frozen_string_literal: true

module ExternalBridge
  module LinkSharing
    # Read boundary for a later boost conversion. It does not create a note
    # and it does not add a public API. Flag off and a broken mapping fail
    # closed. A missing mapping returns nil.
    class Resolve
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
        raise Error, :scope_rejected unless EnsureReference::VISIBILITIES.include?(@scope)

        Feature.require!(@user)
        Ownership.assert!(@user, @projection)
        canonical = NoteText.canonical_url!(@projection.external_resource)
        row = ExternalProjectionLinkReference.find_by(
          user_id: @user.id,
          external_status_projection_id: @projection.id,
          visibility: @scope,
          canonical_url: canonical,
          state: 'active'
        )
        if row.nil?
          raise Error, :reference_broken if broken_identity?(canonical)

          return nil
        end
        raise Error, :reference_broken unless healthy?(row)

        row.reference_status
      end

      private

      def broken_identity?(canonical)
        ExternalProjectionLinkReference.exists?(
          user_id: @user.id,
          external_status_projection_id: @projection.id,
          visibility: @scope,
          canonical_url: canonical,
          state: 'broken'
        )
      end

      def healthy?(row)
        status = row.reference_status
        status.present? && status.deleted_at.nil? && status.external_projection != true && status.account_id == @user.account_id
      end
    end
  end
end
