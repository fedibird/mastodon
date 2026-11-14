# frozen_string_literal: true

module PostDrafts
  # Reads the attachment rows committed for a draft. The file, type, URLs,
  # dimensions, processing, and custom thumbnail come from those rows.
  # The draft snapshot is the copy of ALT and focus that this draft
  # restores, so a save does not write them onto the media row. A revoked
  # delegation, an unfinished file, or a missing stored file stays linked
  # and is omitted from the rendered list.
  class MediaView
    def initialize(draft, viewer)
      @draft = draft
      @viewer = viewer
    end

    def self.retained?(draft)
      new(draft, nil).retained?
    end

    def retained?
      payload_ids.sort == linked_ids.sort
    end

    def restore
      return 'partial' if incomplete? || !retained?

      payload_ids.sort == visible_records.map { |media| media.id.to_s }.sort ? 'complete' : 'partial'
    end

    def documents
      records = visible_records
      return [] if records.empty?

      document_rows(records).map { |row| overlay_snapshot(row) }
    end

    private

    def incomplete?
      @draft.payload.is_a?(Hash) && @draft.payload['media_incomplete'] == true
    end

    def payload_ids
      payload_media.map { |item| item['id'].to_s }
    end

    def payload_media
      media = @draft.payload.is_a?(Hash) ? @draft.payload.dig('input', 'media') : nil
      Array(media).select { |item| item.is_a?(Hash) }
    end

    def snapshot_by_id
      @snapshot_by_id ||= payload_media.index_by { |item| item['id'].to_s }
    end

    def linked_ids
      @draft.post_draft_media_attachments.map { |link| link.media_attachment_id.to_s }
    end

    def visible_records
      @visible_records ||= delegated_sender? ? delegated_records : owned_records
    end

    def ordered_records
      @draft.post_draft_media_attachments.includes(:media_attachment).filter_map(&:media_attachment)
    end

    def owned_records
      ordered_records.select { |media| renderable?(media, @draft.account_id) }
    end

    def delegated_records
      resolution = posting_resolution
      return [] if resolution.nil? || !resolution.delegated?

      ready = ordered_records.select { |media| renderable?(media, resolution.account.id) }
      covered = PostingIdentityMedia.where(
        media_attachment_id: ready.map(&:id),
        grantee_user_id: resolution.delegation.grantee_user_id,
        delegation_id: resolution.delegation.id,
        posting_account_id: resolution.account.id
      ).pluck(:media_attachment_id)
      ready.select { |media| covered.include?(media.id) }
    end

    def renderable?(media, account_id)
      media.local? && media.processing_complete? && media.account_id == account_id && stored_file?(media)
    end

    def stored_file?(media)
      media.file.present? && media.file.exists?
    rescue Errno::ENOENT, Paperclip::Error
      false
    end

    def document_rows(records)
      rendered = ActiveModelSerializers::SerializableResource.new(
        records,
        each_serializer: REST::MediaAttachmentSerializer,
        scope: @viewer,
        scope_name: :current_user
      ).as_json
      list = rendered.is_a?(Array) ? rendered : Array(rendered['media_attachments'] || rendered[:media_attachments])
      list.map(&:deep_stringify_keys)
    end

    def overlay_snapshot(row)
      snapshot = snapshot_by_id[row['id'].to_s]
      return row if snapshot.nil?

      focus = snapshot['focus'].is_a?(Hash) ? snapshot['focus'] : {}
      meta = row['meta'].is_a?(Hash) ? row['meta'].deep_dup : {}
      meta['focus'] = { 'x' => focus.fetch('x', 0), 'y' => focus.fetch('y', 0) }
      row.merge('description' => snapshot['description'].to_s, 'meta' => meta)
    end

    def delegated_sender?
      sender_id.to_s.start_with?('delegated:')
    end

    def sender_id
      return unless @draft.payload.is_a?(Hash)

      @draft.payload.dig('input', 'sender', 'id')
    end

    def posting_resolution
      return nil if @viewer.nil? || @viewer.account_id != @draft.account_id

      PostingIdentity::SendGuard.resolve!(
        user: @viewer,
        posting_identity_id: sender_id,
        purpose: :media_update
      )
    rescue Mastodon::NotPermittedError
      nil
    end
  end
end
