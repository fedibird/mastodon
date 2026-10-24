# frozen_string_literal: true

module ExternalBridge
  module LinkSharing
    # Read side of the E4 share state. Every lookup is keyed by the User id
    # and that User's Account id. A second User of the same Account has other
    # rows, so it reads false and cannot undo. Account#reblogged? is never
    # consulted for a projection.
    #
    # The answer is the (revision, reblogged) row that the
    # external_projection_link_boosts_track_state trigger keeps in the same
    # statement as the boost row. reblogged is true while an active share has a
    # kept wrapper. A pair with no row is revision 0, reblogged false. Both
    # values always come from one row of one statement, so a payload never
    # carries a reblogged from one moment and a revision from another.
    #
    # The feature flag and the policy are not read here: the state is what
    # exists, and Undo stays available when sharing is off.
    module BoostState
      module_function

      Snapshot = Struct.new(:reblogged, :revision) do
        def revision_text
          revision.to_s
        end
      end

      NONE = Snapshot.new(false, 0).freeze

      STATES_SQL = <<~SQL.squish
        SELECT string_agg(
                 link_boost_states.projection_status_id::text || ':' ||
                 link_boost_states.revision::text || ':' ||
                 CASE WHEN link_boost_states.reblogged THEN 't' ELSE 'f' END,
                 ',')
        FROM external_projection_link_boost_states link_boost_states
        INNER JOIN users link_boost_users
          ON link_boost_users.id = link_boost_states.user_id
         AND link_boost_users.account_id = :account_id
        WHERE link_boost_states.user_id = :user_id
          AND link_boost_states.projection_status_id IN (:status_ids)
      SQL

      def snapshot(user, status)
        return NONE if user.nil? || status.nil? || status.id.nil?

        snapshots(user_id: user.id, account_id: user.account_id, status_ids: [status.id])[status.id] || NONE
      end

      def active?(user, status)
        snapshot(user, status).reblogged
      end

      # @return [Hash{Integer => Snapshot}] only the projections that have a row
      def snapshots(user_id:, account_id:, status_ids:)
        ids = Array(status_ids).compact.uniq
        return {} if user_id.nil? || account_id.nil? || ids.empty?

        sql = ActiveRecord::Base.sanitize_sql_array([STATES_SQL, { user_id: user_id, account_id: account_id, status_ids: ids }])
        parse(ActiveRecord::Base.connection.select_value(sql))
      end

      # string_agg of "id:revision:t|f", as selected by StatusRelationshipsPresenter.
      def parse(text)
        text.to_s.split(',').each_with_object({}) do |entry, memo|
          id, revision, flag = entry.split(':')
          memo[id.to_i] = Snapshot.new(flag == 't', revision.to_i)
        end
      end

      # The same predicate as a sub-select for StatusRelationshipsPresenter,
      # so a page needs no extra round trip.
      def presenter_sql
        STATES_SQL
      end
    end
  end
end
