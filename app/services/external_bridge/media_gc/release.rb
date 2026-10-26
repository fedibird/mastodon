# frozen_string_literal: true

module ExternalBridge
  class MediaGc
    # Claims a bounded set of pending intents and destroys only those targets
    # Classify still accepts. Two workers take different rows (SKIP LOCKED).
    # A second pass over a row whose file is already gone marks the intent
    # released and does not look for other unattached uploads.
    class Release
      def self.ids!(attachment_ids:, asset_ids:)
        new.ids!(attachment_ids: attachment_ids, asset_ids: asset_ids)
      end

      def self.drain!(limit:, respect_grace:)
        new.drain!(limit: limit, respect_grace: respect_grace)
      end

      def ids!(attachment_ids:, asset_ids:)
        ids = intent_ids_for(attachment_ids, asset_ids)
        counts = release_records(ids, respect_grace: false)
        MediaGc.kick!
        counts
      end

      def drain!(limit:, respect_grace:)
        claimed = claim!(limit: limit, respect_grace: respect_grace)
        counts = Hash.new(0)
        claimed.each do |id, token|
          counts[execute!(id, token)] += 1
        end
        log_summary(counts, claimed.size == limit)
        { released: counts[:released], retained: counts[:retained], failed: counts[:failed], more: claimed.size == limit }
      end

      private

      def intent_ids_for(attachment_ids, asset_ids)
        ids = MediaGc.normalize_ids(attachment_ids)
        assets = MediaGc.normalize_ids(asset_ids)
        return [] if ids.empty? && assets.empty?

        scope = ExternalMediaGcIntent.pending
        parts = []
        parts << scope.where(target_type: 'media_attachment', target_id: ids) if ids.any?
        parts << scope.where(target_type: 'external_media_asset', target_id: assets) if assets.any?
        parts.reduce { |query, part| query.or(part) }.order(:id).pluck(:id)
      end

      def release_records(ids, respect_grace:)
        counts = Hash.new(0)
        ids.each_slice(MediaGc::BATCH) do |slice|
          claimed = claim!(limit: slice.size, respect_grace: respect_grace, only_ids: slice)
          claimed.each do |id, token|
            counts[execute!(id, token)] += 1
          end
        end
        counts
      end

      def claim!(limit:, respect_grace:, only_ids: nil)
        now = Time.current
        token = SecureRandom.hex(8)
        id_filter = only_ids.present? ? "AND id IN (#{only_ids.map(&:to_i).join(',')})" : ''
        grace = respect_grace ? "AND available_at <= #{connection.quote(now)}" : ''
        sql = <<~SQL.squish
          WITH picked AS (
            SELECT id FROM external_media_gc_intents
            WHERE state = 'pending'
              AND attempt_count < #{MediaGc::MAX_ATTEMPTS.to_i}
              AND (leased_until IS NULL OR leased_until <= #{connection.quote(now)})
              #{grace}
              #{id_filter}
            ORDER BY id
            LIMIT #{limit.to_i}
            FOR UPDATE SKIP LOCKED
          )
          UPDATE external_media_gc_intents AS intents
          SET lease_token = #{connection.quote(token)},
              leased_until = #{connection.quote(now + MediaGc::LEASE)},
              attempt_count = intents.attempt_count + 1,
              updated_at = #{connection.quote(now)}
          FROM picked
          WHERE intents.id = picked.id
          RETURNING intents.id
        SQL
        connection.exec_query(sql).rows.map { |row| [row[0].to_i, token] }
      end

      def execute!(id, token)
        intent = ExternalMediaGcIntent.find_by(id: id, lease_token: token, state: 'pending')
        return :skipped if intent.nil?

        decision = Classify.call(intent)
        case decision.action
        when :release
          destroy_target!(intent)
          mark!(intent, token, 'released', nil)
          :released
        when :missing
          mark!(intent, token, 'released', 'missing')
          :released
        when :retain
          mark!(intent, token, 'retained', decision.code)
          :retained
        else
          retry!(intent, token, decision.code || 'unexpected_error')
          :failed
        end
      rescue ActiveRecord::InvalidForeignKey, ActiveRecord::RecordNotDestroyed
        retry_or_retain!(id, token, 'still_referenced')
        :retained
      rescue ActiveRecord::RecordNotFound
        mark_id!(id, token, 'released', 'missing', nil)
        :released
      rescue StandardError => e
        retry!(id, token, error_code(e))
        :failed
      end

      def destroy_target!(intent)
        case intent.target_type
        when 'media_attachment'
          MediaAttachment.find_by(id: intent.target_id)&.destroy!
        when 'external_media_asset'
          ExternalMediaAsset.find_by(id: intent.target_id)&.destroy!
        else
          raise ActiveRecord::RecordNotFound
        end
      end

      def retry_or_retain!(id, token, code)
        intent = ExternalMediaGcIntent.find_by(id: id, lease_token: token, state: 'pending')
        return if intent.nil?

        fresh = Classify.call(intent)
        if fresh.action == :retain
          mark!(intent, token, 'retained', fresh.code)
        else
          mark!(intent, token, 'retained', code)
        end
      end

      def retry!(intent_or_id, token, code)
        intent = intent_or_id.is_a?(ExternalMediaGcIntent) ? intent_or_id : ExternalMediaGcIntent.find_by(id: intent_or_id, lease_token: token)
        return if intent.nil? || intent.lease_token != token || !intent.pending?

        if intent.attempt_count >= MediaGc::MAX_ATTEMPTS
          mark!(intent, token, 'failed', code)
          return
        end

        now = Time.current
        delay = MediaGc::BACKOFF.fetch([intent.attempt_count - 1, 0].max, MediaGc::BACKOFF.last)
        updated = ExternalMediaGcIntent.where(id: intent.id, lease_token: token, state: 'pending').update_all(
          lease_token: nil,
          leased_until: nil,
          last_error_code: code,
          available_at: now + delay,
          updated_at: now
        )
        Rails.logger.warn("[ExternalBridge::MediaGc] action=retry target_type=#{intent.target_type} target_id=#{intent.target_id} error=#{code}") if updated.positive?
      end

      def mark!(intent, token, state, code)
        mark_id!(intent.id, token, state, code, intent)
      end

      def mark_id!(id, token, state, code, intent)
        now = Time.current
        updated = ExternalMediaGcIntent.where(id: id, lease_token: token, state: 'pending').update_all(
          state: state,
          last_error_code: code,
          lease_token: nil,
          leased_until: nil,
          resolved_at: now,
          updated_at: now
        )
        return if updated.zero?

        Rails.logger.info(
          "[ExternalBridge::MediaGc] action=#{state} target_type=#{intent&.target_type} target_id=#{intent&.target_id} reason=#{intent&.reason} error=#{code}"
        )
      end

      def error_code(error)
        case error
        when Paperclip::Error then 'storage_error'
        when ActiveRecord::ActiveRecordError then 'database_error'
        when Redis::BaseError then 'lock_unknown'
        else 'unexpected_error'
        end
      end

      def log_summary(counts, more)
        Rails.logger.info(
          "[ExternalBridge::MediaGc] summary released=#{counts[:released]} retained=#{counts[:retained]} failed=#{counts[:failed]} more=#{more}"
        )
      end

      def connection
        ExternalMediaGcIntent.connection
      end
    end
  end
end
