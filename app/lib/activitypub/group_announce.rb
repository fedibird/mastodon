# frozen_string_literal: true

module ActivityPub
  # Visibility of a group boost of a mentioned status. A group with a login
  # keeps that user's default privacy as the floor. A group without a login
  # uses public as the floor, so an unlisted original stays unlisted and a
  # nil user cannot be compared.
  module GroupAnnounce
    module_function

    def visibility_for(status, group)
      original = Status.visibilities[status.visibility]
      floor = Status.visibilities[privacy_floor(group)] || Status.visibilities['public']
      return status.visibility if original.nil?

      Status.visibilities.key([original, floor].max)
    end

    def privacy_floor(group)
      return 'public' if group.user.nil?

      group.user.setting_default_privacy.presence || 'public'
    end
  end
end
