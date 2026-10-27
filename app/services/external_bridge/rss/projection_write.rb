# frozen_string_literal: true

module ExternalBridge
  module RSS
    # One projection's status write, shared by import and the display rewrite.
    #
    # The caller already holds the subscription row FOR SHARE (the deletion
    # fence). This then locks the projection row. Import and the rewrite take
    # those locks in that order, so they cannot store two different snapshots
    # of the same article. The resource and status are read only after the
    # projection lock, and the resource row itself is not locked: a feed
    # update does not wait on a subscriber's projection.
    module ProjectionWrite
      module_function

      def latest(marker_id)
        marker = ExternalStatusProjection.lock('FOR UPDATE').find_by(id: marker_id)
        return if marker.nil?

        resource = ExternalResource.find_by(id: marker.external_resource_id)
        status = Status.find_by(id: marker.status_id)
        return if resource.nil? || status.nil?

        yield marker, status, resource
      end
    end
  end
end
