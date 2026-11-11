# frozen_string_literal: true

module StatusSnapshotConcern
  extend ActiveSupport::Concern

  included do
    has_many :edits, class_name: 'StatusEdit', inverse_of: :status, dependent: :destroy
  end

  def edited?
    edited_at.present?
  end

  # emoji_identities:
  #   :capture  — resolve the rows that exist for this text right now
  #   :unproven — this snapshot is backdated and the post never recorded ids
  #   Array     — a snapshot already taken, copied as-is
  def build_snapshot(account_id: nil, at_time: nil, rate_limit: true, emoji_identities: :capture)
    # Build the row directly so saving the status does not persist it.
    # The edit service decides when each snapshot is written.
    edit = StatusEdit.new(
      status: self,
      status_id: id,
      text: text,
      spoiler_text: spoiler_text,
      sensitive: sensitive,
      ordered_media_attachment_ids: ordered_media_attachment_ids&.dup || media_attachments.pluck(:id),
      media_descriptions: ordered_media_attachments.map(&:description),
      poll_options: preloadable_poll&.options&.dup,
      account_id: account_id || self.account_id,
      created_at: at_time || edited_at,
      rate_limit: rate_limit
    )
    edit.emoji_identities = case emoji_identities
                            when :capture
                              # A synthetic snapshot for a status that was never
                              # edited is built at read time, so its ids describe
                              # the text that is current, not an older revision.
                              edit.capture_emoji_identities
                            when :unproven
                              edit.unproven_original_identities
                            else
                              emoji_identities
                            end
    edit
  end

  # The first stored revision stands in for the original post. Use the ids
  # recorded when the status was created. A status from before that column
  # has no proof, so local rows are left out instead of being re-resolved.
  def build_original_snapshot
    recorded = emoji_identities
    if recorded.nil?
      build_snapshot(at_time: created_at, rate_limit: false, emoji_identities: :unproven)
    else
      build_snapshot(at_time: created_at, rate_limit: false, emoji_identities: recorded)
    end
  end

  def snapshot_original!
    build_original_snapshot.save!
  end

  def snapshot!(**options)
    build_snapshot(**options).save!
  end

  # Called once, after the status and its poll exist. Later edits do not
  # overwrite this: it is the proof for the original revision.
  def remember_posted_emoji_identities!
    return unless emoji_identities.nil?

    draft = StatusEdit.new(
      status: self,
      text: text,
      spoiler_text: spoiler_text,
      poll_options: preloadable_poll&.options
    )
    self.emoji_identities = draft.capture_emoji_identities
    update_column(:emoji_identities, emoji_identities)
  end
end
