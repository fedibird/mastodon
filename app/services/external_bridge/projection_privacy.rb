# frozen_string_literal: true

module ExternalBridge
  # projection_private? is the column OR a marker. Either one is enough.
  # A true column with no marker is private for every caller.
  module ProjectionPrivacy
    NOT_PROJECTION_SQL = <<~SQL.squish.freeze
      (statuses.external_projection IS NOT TRUE)
      AND NOT EXISTS (
        SELECT 1 FROM external_status_projections projection_marker
        WHERE projection_marker.status_id = statuses.id
      )
    SQL

    PERSONAL_VISIBILITY_SQL = <<~SQL.squish.freeze
      (
        (statuses.external_projection IS NOT TRUE)
        AND NOT EXISTS (
          SELECT 1 FROM external_status_projections projection_marker
          WHERE projection_marker.status_id = statuses.id
        )
      )
      OR EXISTS (
        SELECT 1 FROM external_status_projections projection_marker
        WHERE projection_marker.status_id = statuses.id
          AND projection_marker.user_id = :viewer_user_id
      )
    SQL

    module_function

    def private_status?(status)
      return false if status.nil?
      return true if status.respond_to?(:external_projection) && status.external_projection == true
      return false unless status.is_a?(Status)
      return false if status.local? == false

      marker_exists?(status)
    end

    def private_id?(status_id)
      return false if status_id.blank?

      status = Status.find_by(id: status_id)
      private_status?(status)
    end

    def private_target?(target)
      private_status?(target)
    end

    def hidden_from?(status, viewer_user_id)
      return false unless private_status?(status)

      !ProjectionAccess.allow?(viewer_user_id, status)
    end

    def visible_status_relation(viewer_user_id)
      Status.where(PERSONAL_VISIBILITY_SQL, viewer_user_id: viewer_user_id.to_i)
    end

    def marker_exists?(status)
      return false if status.nil? || status.id.nil?

      if status.association(:external_status_projection).loaded?
        return status.external_status_projection.present?
      end

      if status.instance_variable_defined?(:@external_projection_marker)
        return status.instance_variable_get(:@external_projection_marker)
      end

      present = ExternalStatusProjection.exists?(status_id: status.id)
      status.instance_variable_set(:@external_projection_marker, present)
      present
    end
  end
end
