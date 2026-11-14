# frozen_string_literal: true

module PostDrafts
  # Replaces one draft's attachment references inside the caller's
  # transaction. Lock order is the owner account, then the draft row, then
  # media_attachments in ascending id. Cleanup and publication lock only
  # media rows, in that same id order, so they do not wait on the account
  # while holding media.
  #
  # Description and focus stay in the draft snapshot. This class does not
  # write them onto the media row, so an older snapshot cannot replace a
  # newer description on that row. The thumbnail stays on the row as well.
  # MediaView copies the snapshot description and focus onto the response.
  # A referenced file stays unattached to a status until a later publish
  # step detaches it first.
  class MediaLinks
    def initialize(owner_account_id)
      @owner_account_id = owner_account_id
    end

    def apply!(draft, payload)
      new_ids = Array(payload.dig('input', 'media')).map { |item| item['id'].to_i }
      previous = PostDraftMediaAttachment.where(post_draft_id: draft.id).pluck(:media_attachment_id)
      locked = lock_media((previous + new_ids).uniq)
      verify!(draft, payload, new_ids, locked) if new_ids.any?
      replace!(draft, new_ids)
    rescue ActiveRecord::RecordNotUnique
      fail!('media_in_use')
    end

    private

    def lock_media(ids)
      return {} if ids.empty?

      MediaAttachment.where(id: ids).order(:id).lock.index_by(&:id)
    end

    def verify!(draft, payload, new_ids, locked)
      missing = new_ids.find { |id| !locked.key?(id) }
      fail!('media_missing', missing) if missing

      records = new_ids.map { |id| locked.fetch(id) }
      resolution = resolution!(payload)
      records.each { |item| verify_record!(item, resolution.account.id) }
      verify_delegation!(resolution, records, new_ids) if resolution.delegated?
      verify_set!(draft, payload, records, new_ids)
    end

    def verify_record!(item, account_id)
      fail!('media_remote', item.id) unless item.local?
      fail!('media_forbidden', item.id) unless item.account_id == account_id
      fail!('media_not_ready', item.id) unless item.processing_complete?
      fail!('media_in_use', item.id) if item.status_id.present? || item.scheduled_status_id.present?
    end

    def verify_delegation!(resolution, records, new_ids)
      records.each do |item|
        fail!('media_forbidden', item.id) unless PostingIdentity::StillImage.acceptable?(item)
      end
      found = PostingIdentityMedia.where(
        media_attachment_id: new_ids,
        grantee_user_id: resolution.delegation.grantee_user_id,
        delegation_id: resolution.delegation.id,
        posting_account_id: resolution.account.id
      ).distinct.count(:media_attachment_id)
      fail!('media_forbidden') unless found == new_ids.size
    end

    def verify_set!(draft, payload, records, new_ids)
      fail!('media_mixed') if records.size > 1 && records.any?(&:audio_or_video?)
      fail!('media_with_poll') if payload.dig('input', 'poll').present? && !Setting.allow_poll_image
      taken = PostDraftMediaAttachment.where(media_attachment_id: new_ids).where.not(post_draft_id: draft.id).pick(:media_attachment_id)
      fail!('media_in_use', taken) if taken
    end

    def resolution!(payload)
      user = Account.find(@owner_account_id).user
      fail!('media_forbidden') if user.nil?

      resolved = PostingIdentity::SendGuard.resolve!(
        user: user,
        posting_identity_id: payload.dig('input', 'sender', 'id'),
        purpose: :media_update
      )
      fail!('media_forbidden') if !resolved.delegated? && resolved.account.id != @owner_account_id

      resolved
    rescue Mastodon::NotPermittedError
      fail!('media_forbidden')
    end

    def replace!(draft, new_ids)
      PostDraftMediaAttachment.where(post_draft_id: draft.id).delete_all
      return if new_ids.empty?

      rows = new_ids.each_with_index.map do |id, position|
        { post_draft_id: draft.id, media_attachment_id: id, position: position }
      end
      PostDraftMediaAttachment.insert_all!(rows)
    end

    def fail!(code, id = nil)
      error = { 'code' => code, 'key' => 'input.media' }
      error['id'] = id.to_s if id
      raise Payload::Invalid, [error]
    end
  end
end
