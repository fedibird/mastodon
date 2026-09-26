# frozen_string_literal: true

class REST::StatusEditSerializer < ActiveModel::Serializer
  has_one :account, serializer: REST::AccountSerializer

  attributes :content, :spoiler_text, :sensitive, :created_at

  has_many :ordered_media_attachments, key: :media_attachments, serializer: REST::MediaAttachmentSerializer
  has_many :emojis, serializer: REST::CustomEmojiSerializer

  attribute :poll, if: -> { object.poll_options.present? }

  def content
    Formatter.instance.format(object.formatting_status, rest: true, emoji_compatibility: true)
  end

  def spoiler_text
    CustomEmoji.with_compatible_boundaries(object.spoiler_text, object.emojis)
  end

  def poll
    {
      options: object.poll_options.map { |title| { title: CustomEmoji.with_compatible_boundaries(title, object.emojis) } },
    }
  end
end
