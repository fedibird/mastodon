# frozen_string_literal: true

module ExternalBridge
  class StreamContentWorker
    include Sidekiq::Worker

    def perform(user_id, projection_id, status_id, subscription_id, generation)
      context = load_context(user_id, projection_id, status_id, subscription_id, generation)
      return if context.nil?

      channels = destination_channels(context)
      return if channels.empty?

      payload = ExternalBridge::Streaming::StatusRenderer.render(context.fetch(:status), context.fetch(:user))
      return if payload.nil?

      event = context.fetch(:marker).streamed_content_generation.nil? ? 'update' : 'status.update'
      publish(channels, event, payload)
      mark_streamed!(context.fetch(:marker))
    rescue Redis::BaseError, ActiveRecord::ActiveRecordError => e
      log_failure(user_id, status_id, projection_id, e)
      raise
    end

    private

    def load_context(user_id, projection_id, status_id, subscription_id, generation)
      return nil unless generation.to_s.match?(/\A[1-9]\d*\z/)

      user = User.find_by(id: user_id)
      return nil unless user&.functional?
      return nil unless ExternalBridge::Feeds::Feature.permitted?(user)

      marker = ExternalStatusProjection.find_by(
        id: projection_id,
        user_id: user.id,
        status_id: status_id,
        external_subscription_id: subscription_id
      )
      return nil if marker.nil? || marker.source_deleted
      return nil if marker.content_generation.to_i != generation.to_i

      streamed = marker.streamed_content_generation
      return nil if streamed.present? && streamed.to_i >= marker.content_generation.to_i

      status = marker.status
      return nil if status.nil?

      { user: user, marker: marker, status: status }
    end

    def destination_channels(context)
      user = context.fetch(:user)
      marker = context.fetch(:marker)
      status = context.fetch(:status)
      channels = []
      append_home(channels, user, status)
      append_lists(channels, user, marker, status)
      channels.uniq
    end

    def append_home(channels, user, status)
      return unless member?(user, status, 'home', nil)

      channel = ExternalBridge::Streaming::Channels.home(user.id)
      channels << channel if channel
    end

    def append_lists(channels, user, marker, status)
      list_ids = ExternalFeedRoute.where(
        user_id: user.id,
        external_subscription_id: marker.external_subscription_id,
        destination: 'list'
      ).pluck(:list_id)
      List.where(id: list_ids, account_id: user.account_id).find_each do |list|
        next unless member?(user, status, 'list', list)

        channel = ExternalBridge::Streaming::Channels.list(user.id, list.id)
        channels << channel if channel
      end
    end

    def member?(user, status, destination, list)
      query = ExternalBridge::Feeds::Query.new(user: user, destination: destination, list: list)
      query.eligible_ids([status.id]).include?(status.id)
    end

    def publish(channels, event, payload)
      publisher = ExternalBridge::Streaming::Publisher.new
      channels.each { |channel| publisher.publish(channel, event, payload) }
    end

    def mark_streamed!(marker)
      ExternalStatusProjection.where(
        id: marker.id,
        content_generation: marker.content_generation,
        streamed_content_generation: marker.streamed_content_generation
      ).update_all(streamed_content_generation: marker.content_generation, updated_at: Time.current)
    end

    def log_failure(user_id, status_id, projection_id, error)
      Rails.logger.warn(
        "[ExternalBridge::Streaming] content user_id=#{user_id} status_id=#{status_id} " \
        "projection_id=#{projection_id} error=#{error.class}"
      )
    end
  end
end
