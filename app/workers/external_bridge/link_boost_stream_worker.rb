# frozen_string_literal: true

module ExternalBridge
  # Publishes the current share state of one projection to the owner's private
  # boost channel. The payload is the (revision, reblogged) row as it is when
  # this job runs, so an old job never publishes an old pair. It does not read
  # the E3 or E4 feature flags: a state change that already happened is the
  # owner's own, and Undo works while sharing is off. It carries no body, URL,
  # reference id, or wrapper id.
  class LinkBoostStreamWorker
    include Sidekiq::Worker

    sidekiq_options retry: 5

    EVENT = 'external_link_boost_changed'

    def perform(user_id, status_id)
      user = User.find_by(id: user_id)
      status = status_id.to_i
      return acknowledge(user_id, status) unless user&.functional?
      return acknowledge(user_id, status) unless ExternalStatusProjection.exists?(user_id: user.id, status_id: status_id)

      state = ExternalBridge::LinkSharing::BoostState.snapshots(
        user_id: user.id,
        account_id: user.account_id,
        status_ids: [status]
      )[status]
      return if state.nil?

      channel = ExternalBridge::Streaming::Channels.boost(user.id)
      return if channel.nil?

      status_text = status_id.to_s
      ExternalBridge::Streaming::Publisher.new.publish(
        channel,
        EVENT,
        { 'version' => 1, 'status_id' => status_text, 'reblogged' => state.reblogged, 'revision' => state.revision_text },
        delivery: { 'kind' => 'boost', 'user_id' => user.id.to_s, 'status_id' => status_text, 'revision' => state.revision_text }
      )
      acknowledge(user.id, status, state.revision)
    rescue Redis::BaseError, ActiveRecord::ActiveRecordError => e
      Rails.logger.warn("[ExternalBridge::Streaming] boost user_id=#{user_id} status_id=#{status_id} error=#{e.class}")
      raise
    end

    private

    # Records that every revision up to this one has been published, or has
    # nobody to be published to. A flip that lands after the read stays above
    # this mark, so the recovery pass still finds it.
    def acknowledge(user_id, status_id, revision = nil)
      scope = ExternalProjectionLinkBoostState.where(user_id: user_id, projection_status_id: status_id)
      scope = scope.where('notified_revision < ?', revision) if revision
      revision ? scope.update_all(notified_revision: revision) : scope.update_all('notified_revision = revision')
    end
  end
end
