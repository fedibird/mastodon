# frozen_string_literal: true

# Mastodon v4.2 notifies mentions from FanOutOnWriteService during an Update.
# Fedibird fan-out does not, so a significant explicit edit notifies newly
# explicit local mentions here, after the edit transaction commits.
# Audience matches ActivityPub::Activity::Create: object to/cc, then activity to/cc.
# A local group that this edit mentions for the first time is distributed the
# way Create does, and only for a live delivery.
module ActivityPub::ProcessStatusUpdateDistribution
  private

  def notify_new_explicit_mentions!
    return unless significant_changes?

    @newly_explicit_mentions.each do |mention|
      account = mention.account
      next unless account&.local? && audience_includes?(account)
      next if mention_notification_exists?(account, mention)

      NotifyService.new.call(account, :mention, mention)
    end
  end

  def mention_notification_exists?(account, mention)
    Notification.exists?(account_id: account.id, activity_type: 'Mention', activity_id: mention.id)
  end

  def distribute_to_new_local_groups!
    return unless @delivery

    group_ids = @newly_explicit_mentions.filter_map { |mention| mention.account_id if local_group_account?(mention.account) }
    return if group_ids.empty?
    return unless Account.local.groups.where(id: group_ids).joins(:passive_relationships).exists?

    ActivityPub::GroupDistributionWorker.perform_async(@status.id)
  end

  def local_group_account?(account)
    account.present? && account.local? && account.group?
  end

  def audience_includes?(account)
    uri = ActivityPub::TagManager.instance.uri_for(account)
    audience_to.include?(uri) || audience_cc.include?(uri)
  end

  def audience_to
    as_array(@json['to'] || @activity_json['to']).map { |item| value_or_id(item) }
  end

  def audience_cc
    as_array(@json['cc'] || @activity_json['cc']).map { |item| value_or_id(item) }
  end
end
