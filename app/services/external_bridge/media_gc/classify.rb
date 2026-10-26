# frozen_string_literal: true

module ExternalBridge
  class MediaGc
    # Decides whether a planned target may be destroyed. Read-only.
    # Missing rows are success: a previous attempt already removed them.
    class Classify
      Decision = Struct.new(:action, :code, keyword_init: true)

      def self.call(intent)
        new(intent).call
      end

      def initialize(intent)
        @intent = intent
      end

      def call
        case @intent.target_type
        when 'media_attachment' then attachment_decision
        when 'external_media_asset' then asset_decision
        else
          retain('unproven')
        end
      end

      private

      def attachment_decision
        attachment = MediaAttachment.find_by(id: @intent.target_id)
        return missing if attachment.nil?
        return retain('unproven') unless proven_attachment?
        return retain('owner_mismatch') if attachment.account_id != @intent.owner_account_id
        return retain('scheduled_status') if attachment.scheduled_status_id.present?
        return retain('projection_link') if ExternalProjectionAttachment.exists?(media_attachment_id: attachment.id)
        return retain('storage_mismatch') unless storage_owned?(attachment)

        send(:"classify_#{@intent.reason}", attachment)
      rescue NoMethodError
        retain('unproven')
      end

      def classify_projection_purge(attachment)
        return retain('status_still_present') if Status.unscoped.exists?(id: @intent.captured_status_id)
        return retain('live_status') if attachment.status_id.present?

        release
      end

      def classify_attachment_replaced(attachment)
        return retain('live_status') if attachment.status_id.present? && attachment.status_id != @intent.captured_status_id

        status = Status.unscoped.find_by(id: @intent.captured_status_id)
        if status
          return retain('not_projection') unless status.external_projection == true
          return retain('live_status') if attachment.status_id.blank?

          return release
        end

        # The captured projection was purged before this replacement intent
        # ran. Purge does not plan the old file again: its link is already
        # gone. The attachment is eligible once it is off every status.
        return retain('live_status') if attachment.status_id.present?

        release
      end

      def asset_decision
        asset = ExternalMediaAsset.find_by(id: @intent.target_id)
        return missing if asset.nil?
        return retain('still_referenced') if ExternalProjectionAttachment.exists?(external_media_asset_id: asset.id)

        lock = url_locked?(asset)
        return retry_later('url_locked') if lock == true
        return retry_later('lock_unknown') if lock == :unknown
        return retain('storage_mismatch') unless storage_owned?(asset)

        release
      end

      def proven_attachment?
        proof = proof_row
        return false if proof.nil?
        return false unless proof.media_attachment_id == @intent.target_id
        return false unless proof.external_status_projection_id == @intent.captured_projection_id
        return false unless proof.account_id == @intent.owner_account_id
        return false unless proof.status_id == @intent.captured_status_id

        live_proof_matches?(proof)
      end

      def proof_row
        return nil if @intent.source_attachment_id.blank? || @intent.captured_projection_id.blank? || @intent.owner_account_id.blank?

        ExternalMediaGcProof.find_by(source_attachment_id: @intent.source_attachment_id)
      end

      # A link or projection that is still present must be the one the proof
      # names. After purge both rows are gone; the proof row is the record.
      def live_proof_matches?(proof)
        link = ExternalProjectionAttachment.find_by(id: proof.source_attachment_id)
        if link
          return false unless link.media_attachment_id == proof.media_attachment_id
          return false unless link.external_status_projection_id == proof.external_status_projection_id
        end

        projection = ExternalStatusProjection.find_by(id: proof.external_status_projection_id)
        if projection
          return false unless projection.account_id == proof.account_id
          return false unless projection.status_id == proof.status_id
        end

        true
      end

      def storage_owned?(record)
        attachment = record.file
        return true if attachment.original_filename.blank?

        path = attachment.path.to_s
        return false if path.empty?

        partition = Paperclip::Interpolations.id_partition(attachment, :original)
        klass = Paperclip::Interpolations.class(attachment, :original)
        path.include?("/#{klass}/") && path.include?("/#{partition}/")
      rescue StandardError
        false
      end

      def url_locked?(asset)
        return false if asset.url_digest.blank?

        key = "external_bridge:rss_media:url:#{asset.url_digest}"
        locked = false
        RedisConfiguration.with { |redis| locked = redis.exists?(key) }
        locked
      rescue StandardError
        :unknown
      end

      def release
        Decision.new(action: :release, code: nil)
      end

      def missing
        Decision.new(action: :missing, code: 'missing')
      end

      def retain(code)
        Decision.new(action: :retain, code: code)
      end

      def retry_later(code)
        Decision.new(action: :retry, code: code)
      end
    end
  end
end
