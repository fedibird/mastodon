# frozen_string_literal: true

module ActivityPub
  # Whether a local group boosts a mentioned status. ProcessMentionsService
  # and GroupDistributionWorker both use this. A follow request is not a
  # follow. Only a public or unlisted original is announced. A group with a
  # login keeps that user's default privacy as the floor, so the boost is
  # never more public than that setting. A group without a login uses
  # public as the floor. Remote groups are not boosted here.
  module GroupAnnounce
    ANNOUNCEABLE_VISIBILITIES = %w(public unlisted).freeze

    module_function

    def announce?(status, group)
      return false if group.nil? || status.nil?
      return false unless group.local? && group.group?
      return false unless ANNOUNCEABLE_VISIBILITIES.include?(status.visibility.to_s)

      author = status.account
      return false if author.nil?

      author.following?(group)
    end

    def visibility_for(status, group)
      original = Status.visibilities[status.visibility.to_s]
      return status.visibility if original.nil?

      floor = Status.visibilities[privacy_floor(group)] || Status.visibilities['public']
      Status.visibilities.key([original, floor].max)
    end

    def privacy_floor(group)
      return 'public' if group.user.nil?

      group.user.setting_default_privacy.presence || 'public'
    end
  end
end
