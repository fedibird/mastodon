# frozen_string_literal: true

module ExternalBridge
  module Streaming
    # Enqueues ids and a generation after the outermost commit.
    # Job arguments never include status text, URLs, or tokens.
    class Scheduler
      DELETE_BATCH = 100
      REASONS = %w(routes_updated source_deleted source_restored list_removed subscription_removed).freeze

      def self.bump_and_schedule_content!(marker)
        return unless content_enqueueable?(marker)

        marker.update_columns(content_generation: marker.content_generation.to_i + 1)
        schedule_content!(marker)
      end

      def self.schedule_content!(marker)
        return unless content_enqueueable?(marker)

        generation = marker.content_generation.to_i
        return if generation <= 0

        args = [
          marker.user_id.to_s,
          marker.id.to_s,
          marker.status_id.to_s,
          marker.external_subscription_id.to_s,
          generation.to_s,
        ]
        AfterOuterCommit.run { StreamContentWorker.perform_async(*args) }
      end

      def self.content_enqueueable?(marker)
        return false if marker.nil? || marker.source_deleted

        user = marker.user
        user&.functional? && Feeds::Feature.permitted?(user) && canonical?(marker.status)
      end

      def self.schedule_control!(**delivery)
        user = User.find_by(id: delivery[:user_id])
        return unless user&.functional? && Feeds::Feature.permitted?(user)

        payload = control_payload(delivery)
        return if payload.nil?

        user_id = user.id.to_s
        internal = route_epoch_delivery(delivery[:epochs], payload['subscription_id'])
        AfterOuterCommit.run do
          if internal
            StreamControlWorker.perform_async(user_id, payload, internal)
          else
            StreamControlWorker.perform_async(user_id, payload)
          end
        end
      end

      # Pushes a control event now, outside AfterOuterCommit. The caller is
      # already past the commit that made the event true.
      #
      # @return [Symbol]
      #   :pushed  Sidekiq returned a job id
      #   :failed  perform_async returned nil or false (the client did not accept it)
      #   :skipped nobody to tell: the user cannot receive it, or the payload is empty
      # Redis errors are raised. A nil id is not success.
      def self.deliver_control!(**delivery)
        user = User.find_by(id: delivery[:user_id])
        return :skipped unless user&.functional? && Feeds::Feature.permitted?(user)

        payload = control_payload(delivery)
        return :skipped if payload.nil?

        jid = StreamControlWorker.perform_async(user.id.to_s, payload)
        jid.present? ? :pushed : :failed
      end

      def self.schedule_deletes!(captures)
        Array(captures).each_slice(DELETE_BATCH) do |batch|
          cleaned = batch.filter_map { |row| clean_delete(row) }
          next if cleaned.empty?

          # After the outermost commit. A Redis error here must not escape:
          # Rails 6.1 delivers it to the caller after the DELETE has committed.
          # Callers that can retry keep their own outbox and use push_deletes!.
          AfterOuterCommit.run { push_delete_batch!(cleaned) }
        end
      end

      # Pushes now. Use this only after the DELETE is already durable.
      #
      # @return [Hash] :accepted captures Sidekiq took, :discarded rows that
      #   can never be sent. A nil job id or a raised error accepts nothing
      #   further; the caller keeps those rows.
      def self.push_deletes!(captures)
        accepted = []
        discarded = []
        Array(captures).each_slice(DELETE_BATCH) do |batch|
          cleaned = []
          batch.each do |row|
            entry = clean_delete(row)
            entry ? cleaned << entry : discarded << row
          end
          next if cleaned.empty?

          jid = push_delete_batch!(cleaned)
          if jid.present?
            accepted.concat(cleaned)
          else
            break
          end
        end
        { accepted: accepted, discarded: discarded }
      end

      def self.push_delete_batch!(cleaned)
        jid = StreamDeleteWorker.perform_async(cleaned)
        Rails.logger.warn('[ExternalBridge::Streaming] delete enqueue rejected') if jid.blank?
        jid
      rescue StandardError => e
        Rails.logger.warn("[ExternalBridge::Streaming] delete enqueue error=#{e.class}")
        nil
      end
      private_class_method :push_delete_batch!

      def self.canonical?(status)
        status.present? &&
          status.external_projection == true &&
          status.external_visibility? &&
          status.personal_searchability? &&
          status.local? &&
          status.uri.nil? &&
          status.reply != true &&
          status.reblog_of_id.nil? &&
          status.quote_id.nil? &&
          status.deleted_at.nil? &&
          status.expired_at.nil?
      end

      def self.control_payload(delivery)
        reason = delivery[:reason].to_s
        return nil unless REASONS.include?(reason)

        subscription_id = Channels.decimal_id(delivery[:subscription_id])
        revision = Channels.revision_text(delivery[:revision])
        targets = normalize_targets(delivery[:targets])
        return nil if subscription_id.nil? || revision.nil? || targets.empty?

        payload = {
          'version' => 1,
          'reason' => reason,
          'targets' => targets,
          'subscription_id' => subscription_id,
          'feed_routes_revision' => revision,
        }
        assign_status_id!(payload, delivery[:status_id], reason)
        payload
      end

      def self.assign_status_id!(payload, status_id, reason)
        return unless %w(source_deleted source_restored).include?(reason)

        text = Channels.decimal_id(status_id)
        payload['status_id'] = text if text
      end

      def self.normalize_targets(targets)
        Array(targets).filter_map { |target| normalize_target(target) }.uniq
      end

      def self.normalize_target(target)
        type = target_type(target)
        return { 'type' => 'home' } if type == 'home'

        list_id = Channels.decimal_id(target_list_id(target))
        return nil if type != 'list' || list_id.nil?

        { 'type' => 'list', 'id' => list_id }
      end

      def self.target_type(target)
        return target['type'] || target[:type] if target.respond_to?(:[])

        nil
      end

      def self.target_list_id(target)
        return nil unless target.respond_to?(:[])

        target['id'] || target[:id] || target['list_id'] || target[:list_id]
      end

      def self.route_epoch_delivery(epochs, subscription_id)
        cleaned = Array(epochs).filter_map { |epoch| clean_epoch(epoch) }
        return nil if cleaned.empty? || subscription_id.nil?

        { 'kind' => 'routes', 'subscription_id' => subscription_id, 'epochs' => cleaned }
      end

      def self.clean_epoch(epoch)
        return nil unless epoch.is_a?(Hash)

        type = epoch['type'] || epoch[:type]
        route_id = Channels.decimal_id(epoch['route_id'] || epoch[:route_id])
        removed_id = Channels.decimal_id(epoch['removed_route_id'] || epoch[:removed_route_id])
        return nil if route_id.nil? && removed_id.nil?

        if type == 'home'
          entry = { 'type' => 'home' }
        elsif type == 'list'
          list_id = Channels.decimal_id(epoch['id'] || epoch[:id] || epoch['list_id'] || epoch[:list_id])
          return nil if list_id.nil?

          entry = { 'type' => 'list', 'id' => list_id }
        else
          return nil
        end

        entry['route_id'] = route_id if route_id
        entry['removed_route_id'] = removed_id if removed_id
        entry
      end

      def self.clean_delete(row)
        return nil unless row.is_a?(Hash)

        user_id = Channels.decimal_id(row['user_id'] || row[:user_id])
        status_id = Channels.decimal_id(row['status_id'] || row[:status_id])
        subscription_id = Channels.decimal_id(row['subscription_id'] || row[:subscription_id])
        destinations = normalize_targets(row['destinations'] || row[:destinations])
        return nil if user_id.nil? || status_id.nil? || subscription_id.nil? || destinations.empty?

        {
          'user_id' => user_id,
          'status_id' => status_id,
          'subscription_id' => subscription_id,
          'destinations' => destinations,
        }
      end

      private_class_method :control_payload, :assign_status_id!, :normalize_targets, :normalize_target,
                           :target_type, :target_list_id, :route_epoch_delivery, :clean_epoch, :clean_delete
    end
  end
end
