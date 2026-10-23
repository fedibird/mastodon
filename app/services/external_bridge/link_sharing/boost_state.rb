# frozen_string_literal: true

module ExternalBridge
  module LinkSharing
    # Read side of the E4-B share state. Every lookup is keyed by the User id
    # and that User's Account id. A second User of the same Account has other
    # rows, so it reads false and cannot undo. Account#reblogged? is never
    # consulted for a projection.
    #
    # A row counts only while its wrapper is still a kept Status. A wrapper
    # discarded by some other path stops being a share without waiting for the
    # row to be closed. The feature flag and the policy are not read here: the
    # state is what exists, and Undo stays available when sharing is off.
    module BoostState
      module_function

      ACTIVE_PROJECTION_IDS_SQL = <<~SQL.squish
        SELECT string_agg(link_boosts.projection_status_id::text, ',')
        FROM external_projection_link_boosts link_boosts
        INNER JOIN statuses link_boost_wrappers ON link_boost_wrappers.id = link_boosts.wrapper_status_id
        WHERE link_boosts.user_id = :user_id
          AND link_boosts.account_id = :account_id
          AND link_boosts.state = 'active'
          AND link_boost_wrappers.deleted_at IS NULL
          AND link_boosts.projection_status_id IN (:status_ids)
      SQL

      def active?(user, status)
        return false if user.nil? || status.nil? || status.id.nil?

        active_projection_ids(user_id: user.id, account_id: user.account_id, status_ids: [status.id]).include?(status.id)
      end

      def active_projection_ids(user_id:, account_id:, status_ids:)
        ids = Array(status_ids).compact.uniq
        return [] if user_id.nil? || account_id.nil? || ids.empty?

        sql = ActiveRecord::Base.sanitize_sql_array([ACTIVE_PROJECTION_IDS_SQL, { user_id: user_id, account_id: account_id, status_ids: ids }])
        ActiveRecord::Base.connection.select_value(sql).to_s.split(',').map(&:to_i)
      end

      # The same predicate as a sub-select for StatusRelationshipsPresenter,
      # so a page needs no extra round trip.
      def presenter_sql
        ACTIVE_PROJECTION_IDS_SQL
      end
    end
  end
end
