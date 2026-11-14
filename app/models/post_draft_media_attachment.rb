# frozen_string_literal: true

# == Schema Information
#
# Table name: post_draft_media_attachments
#
#  id                  :bigint(8)        not null, primary key
#  post_draft_id       :bigint(8)        not null
#  media_attachment_id :bigint(8)        not null
#  position            :integer          not null
#
# The draft owns the reference and the display order. Description, focus,
# and thumbnail stay on media_attachments. Publishing a draft is not done
# here: a referenced file cannot be moved onto a status or scheduled post.
class PostDraftMediaAttachment < ApplicationRecord
  belongs_to :post_draft, inverse_of: :post_draft_media_attachments
  belongs_to :media_attachment, inverse_of: :post_draft_media_attachment

  validates :position, presence: true, numericality: {
    only_integer: true,
    greater_than_or_equal_to: 0,
    less_than: MediaAttachment::ATTACHMENTS_LIMIT,
  }
end
