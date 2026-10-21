# frozen_string_literal: true

module ExternalBridge
  # A row is private when any one signal is present:
  # visibility external, external_projection true, or a marker.
  # A true signal with no marker is private for every caller, including the
  # account holder. Read permission is a separate marker user_id check.
  module ProjectionPrivacy
    NOT_PROJECTION_SQL = <<~SQL.squish.freeze
      (statuses.visibility IS DISTINCT FROM #{Schema::EXTERNAL_VISIBILITY})
      AND (statuses.external_projection IS NOT TRUE)
      AND NOT EXISTS (
        SELECT 1 FROM external_status_projections projection_marker
        WHERE projection_marker.status_id = statuses.id
      )
    SQL

    # Non-projections, plus a projection whose marker belongs to the viewer.
    # PersonalFeed also requires visibility personal, so an external row is
    # not added to the personal timeline by this predicate.
    PERSONAL_VISIBILITY_SQL = <<~SQL.squish.freeze
      (
        (statuses.visibility IS DISTINCT FROM #{Schema::EXTERNAL_VISIBILITY})
        AND (statuses.external_projection IS NOT TRUE)
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

    def external_signal?(status)
      return false if status.nil?
      return true if status.respond_to?(:external_visibility?) && status.external_visibility?
      return false unless status.respond_to?(:visibility)

      value = status.visibility
      raw = status.respond_to?(:visibility_before_type_cast) ? status.visibility_before_type_cast : value
      [value, raw].any? { |item| external_value?(item) }
    end

    def external_value?(value)
      return false if value.nil?

      token = value.to_s.strip
      token.casecmp(Visibility::NAME).zero? || token == Schema::EXTERNAL_VISIBILITY.to_s || value == Schema::EXTERNAL_VISIBILITY
    end

    def private_status?(status)
      return false if status.nil?
      return true if external_signal?(status)
      return true if status.respond_to?(:external_projection) && status.external_projection == true
      return false unless status.is_a?(Status)

      # A marker is enough even when uri/local and the column disagree.
      # local? must not make a marked row federatable.
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
      return status.instance_variable_get(:@external_projection_marker) if status.instance_variable_defined?(:@external_projection_marker)

      if status.association(:external_status_projection).loaded?
        projection = status.external_status_projection
        status.instance_variable_set(:@external_projection_marker, projection.present?)
        status.instance_variable_set(:@external_projection_owner_id, projection&.user_id)
        return projection.present?
      end

      # One indexed read records the owner too. allow? then answers from this
      # cache, including when the column and the marker disagree.
      owner_id = ExternalStatusProjection.where(status_id: status.id).pick(:user_id)
      status.instance_variable_set(:@external_projection_marker, !owner_id.nil?)
      status.instance_variable_set(:@external_projection_owner_id, owner_id)
      !owner_id.nil?
    end
  end
end
