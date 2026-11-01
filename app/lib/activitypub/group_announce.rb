# frozen_string_literal: true

module ActivityPub
  # Whether a local group boosts a mentioned status. ProcessMentionsService
  # and GroupDistributionWorker both use this, so a local post cannot skip
  # the follow check that remote delivery already had. A follow request is
  # not a follow. Only public and unlisted are announced, and the boost
  # keeps that visibility. The group's login default does not widen or
  # tighten it. Remote groups are not boosted here.
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

    def visibility_for(status, _group)
      status.visibility
    end
  end
end
