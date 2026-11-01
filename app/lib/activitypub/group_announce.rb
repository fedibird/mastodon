# frozen_string_literal: true

module ActivityPub
  # Whether a local group boosts a mentioned status. ProcessMentionsService
  # and GroupDistributionWorker both use this. The mention must be an
  # active Mention row, not a silent audience and not a tag guessed from
  # the text. A follow request is not a follow. Only a public or unlisted
  # original is announced. A group with a login keeps that user's default
  # privacy as the floor. A group without a login uses public. Remote
  # groups are not boosted here.
  module GroupAnnounce
    ANNOUNCEABLE_VISIBILITIES = %w(public unlisted).freeze

    module_function

    def announce?(status, group)
      return false if group.nil? || status.nil?
      return false unless group.local? && group.group?
      return false unless ANNOUNCEABLE_VISIBILITIES.include?(status.visibility.to_s)
      return false unless explicit_mention?(status, group)

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

    def explicit_mention?(status, group)
      status.mentions.active.where(account_id: group.id).exists?
    end
  end
end
