# frozen_string_literal: true

# == Schema Information
#
# Table name: status_edits
#
#  id                           :bigint(8)        not null, primary key
#  status_id                    :bigint(8)        not null
#  account_id                   :bigint(8)
#  text                         :text             default(""), not null
#  spoiler_text                 :text             default(""), not null
#  ordered_media_attachment_ids :bigint(8)        is an Array
#  media_descriptions           :text             is an Array
#  poll_options                 :string           is an Array
#  sensitive                    :boolean
#  created_at                   :datetime         not null
#  updated_at                   :datetime         not null
#

class StatusEdit < ApplicationRecord
  include RateLimitable

  class PreservedMediaAttachment < ActiveModelSerializers::Model
    attributes :media_attachment, :description

    delegate_missing_to :media_attachment
  end

  # Formats a historical edit with the parent status's mentions, quote, and
  # references while using this revision's text.
  class FormattingStatus < SimpleDelegator
    def initialize(status, edit)
      super(status)
      @edit = edit
    end

    def text
      @edit.text
    end

    def spoiler_text
      @edit.spoiler_text
    end

    def reblog?
      false
    end

    def proper
      self
    end

    def emojis
      @edit.emojis
    end
  end

  rate_limit by: :account, family: :statuses

  belongs_to :status
  belongs_to :account, optional: true

  default_scope { order(id: :asc) }

  delegate :local?, :application, :edited?, :edited_at,
           :discarded?, :visibility, to: :status

  def emojis
    return @emojis if defined?(@emojis)

    @emojis = CustomEmoji.from_text([spoiler_text, text].join(' '), status.account.domain)
  end

  def ordered_media_attachments
    return @ordered_media_attachments if defined?(@ordered_media_attachments)

    descriptions = media_descriptions || []
    @ordered_media_attachments = if ordered_media_attachment_ids.nil?
                                   []
                                 else
                                   map = status.media_attachments.index_by(&:id)
                                   ordered_media_attachment_ids.each_with_index.map do |media_attachment_id, index|
                                     attachment = map[media_attachment_id]
                                     next if attachment.nil?

                                     PreservedMediaAttachment.new(media_attachment: attachment, description: descriptions[index])
                                   end.compact
                                 end
  end

  def formatting_status
    FormattingStatus.new(status, self)
  end

  def proper
    self
  end

  def reblog?
    false
  end
end
