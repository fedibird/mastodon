# frozen_string_literal: true

module ExternalBridge
  class MediaGc
    # Inserts pending intents. Attachment rows are inserted only when an
    # external_projection_attachments row still points at them, and only with
    # the owner and status captured from that link. A compose upload has no
    # such link, so it is skipped. Callers must run this before the purge
    # DELETE or before the projection link is destroyed.
    class Plan
      COLUMNS = %i(
        target_type target_id reason state owner_account_id captured_status_id
        source_attachment_id external_subscription_deletion_id available_at
        attempt_count created_at updated_at
      ).freeze

      def self.purge!(media, deletion_id: nil)
        captured = media.is_a?(Hash) ? media : {}
        new(
          attachment_ids: captured[:attachment_ids],
          asset_ids: captured[:asset_ids],
          attachment_reason: 'projection_purge',
          asset_reason: 'projection_purge',
          deletion_id: deletion_id
        ).insert!
      end

      def self.replacement!(attachment_ids:, asset_ids:)
        new(
          attachment_ids: attachment_ids,
          asset_ids: asset_ids,
          attachment_reason: 'attachment_replaced',
          asset_reason: 'asset_unreferenced',
          deletion_id: nil
        ).insert!
      end

      def self.generation!(asset_id)
        new(
          attachment_ids: [],
          asset_ids: [asset_id],
          attachment_reason: 'projection_purge',
          asset_reason: 'generation_replaced',
          deletion_id: nil
        ).insert!
      end

      def initialize(attachment_ids:, asset_ids:, attachment_reason:, asset_reason:, deletion_id:)
        @attachment_ids = MediaGc.normalize_ids(attachment_ids)
        @asset_ids = MediaGc.normalize_ids(asset_ids)
        @attachment_reason = attachment_reason
        @asset_reason = asset_reason
        @deletion_id = deletion_id.to_i.nonzero?
        @now = Time.current
      end

      def insert!
        rows = attachment_rows + asset_rows
        return 0 if rows.empty?

        rows.each_slice(100) { |slice| insert_slice!(slice) }
        rows.size
      end

      private

      def attachment_rows
        return [] if @attachment_ids.empty?

        links = ExternalProjectionAttachment.where(media_attachment_id: @attachment_ids).includes(:media_attachment)
        links.filter_map { |link| attachment_row(link) }
      end

      def attachment_row(link)
        attachment = link.media_attachment
        if attachment.nil? || attachment.account_id.blank? || attachment.status_id.blank?
          Rails.logger.warn("[ExternalBridge::MediaGc] step=plan skipped=unproven target_type=media_attachment target_id=#{link.media_attachment_id}")
          return nil
        end

        row('media_attachment', attachment.id, @attachment_reason, [attachment.account_id, attachment.status_id, link.id])
      end

      def asset_rows
        return [] if @asset_ids.empty?

        ExternalMediaAsset.where(id: @asset_ids).pluck(:id).map do |asset_id|
          row('external_media_asset', asset_id, @asset_reason, [])
        end
      end

      def row(target_type, target_id, reason, proof)
        owner_account_id, captured_status_id, source_attachment_id = proof
        {
          target_type: target_type,
          target_id: target_id,
          reason: reason,
          state: 'pending',
          owner_account_id: owner_account_id,
          captured_status_id: captured_status_id,
          source_attachment_id: source_attachment_id,
          external_subscription_deletion_id: @deletion_id,
          available_at: @now + MediaGc.grace,
          attempt_count: 0,
          created_at: @now,
          updated_at: @now,
        }
      end

      def insert_slice!(slice)
        quoted = slice.map { |item| "(#{COLUMNS.map { |column| connection.quote(item[column]) }.join(',')})" }
        connection.execute(<<~SQL.squish)
          INSERT INTO external_media_gc_intents (#{COLUMNS.join(',')})
          VALUES #{quoted.join(',')}
          ON CONFLICT (target_type, target_id) WHERE state = 'pending' DO NOTHING
        SQL
      end

      def connection
        ExternalMediaGcIntent.connection
      end
    end
  end
end
