# frozen_string_literal: true

module ExternalBridge
  class StreamDeleteWorker
    include Sidekiq::Worker

    def perform(entries)
      Array(entries).each { |entry| publish_one(entry) }
    rescue Redis::BaseError, ActiveRecord::ActiveRecordError => e
      Rails.logger.warn("[ExternalBridge::Streaming] delete error=#{e.class}")
      raise
    end

    private

    def publish_one(entry)
      return unless entry.is_a?(Hash)

      user = User.find_by(id: entry['user_id'])
      return unless user&.functional?
      return unless ExternalBridge::Feeds::Feature.permitted?(user)

      status_id = ExternalBridge::Streaming::Channels.decimal_id(entry['status_id'])
      return if status_id.nil?
      return if Status.unscoped.where(id: status_id).exists?
      return if ExternalStatusProjection.where(status_id: status_id, user_id: user.id).exists?

      publisher = ExternalBridge::Streaming::Publisher.new
      Array(entry['destinations']).each do |destination|
        channel = channel_for(user.id, destination)
        next if channel.nil?

        delivery = {
          'kind' => 'delete',
          'user_id' => user.id.to_s,
          'status_id' => status_id,
        }
        publisher.publish(channel, 'delete', status_id, delivery: delivery)
      end
    end

    def channel_for(user_id, destination)
      type = destination.is_a?(Hash) ? (destination['type'] || destination[:type]) : nil
      return ExternalBridge::Streaming::Channels.home(user_id) if type == 'home'
      return nil unless type == 'list'

      list_id = destination['id'] || destination[:id]
      ExternalBridge::Streaming::Channels.list(user_id, list_id)
    end
  end
end
