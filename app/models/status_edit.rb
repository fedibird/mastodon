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
#  emoji_identities             :jsonb
#  created_at                   :datetime         not null
#  updated_at                   :datetime         not null
#

class StatusEdit < ApplicationRecord
  include RateLimitable

  class PreservedMediaAttachment < ActiveModelSerializers::Model
    attributes :media_attachment, :description

    delegate :id, :to_param, to: :media_attachment
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

  # Local mute identity is the row id at the moment this revision was saved.
  # `emoji_identities` is that snapshot. A later row that reuses the shortcode
  # is a different emoji. Stored revisions from before the snapshot exist
  # (`nil`) and do not borrow whatever `from_text` would find now.
  def emojis
    return @emojis if defined?(@emojis)

    @emojis = if emoji_identities.nil?
                legacy_unproven_emojis
              else
                emojis_from_identities
              end
  end

  # Called from Status#build_snapshot while the status still has this text.
  # An empty array is a real snapshot of "no custom emoji", distinct from nil.
  def capture_emoji_identities
    parts = [spoiler_text, text]
    parts.concat(poll_options) if poll_options.present?
    domain = status&.account&.domain

    CustomEmoji.from_text(parts.compact.join(' '), domain).map do |emoji|
      {
        'id' => emoji.domain.blank? ? emoji.id.to_s : nil,
        'shortcode' => emoji.shortcode,
        'domain' => emoji.domain,
      }
    end
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

  private

  def legacy_unproven_emojis
    parts = [spoiler_text, text]
    parts.concat(poll_options) if poll_options.present?
    domain = status&.account&.domain

    CustomEmoji.from_text(parts.compact.join(' '), domain).reject { |emoji| emoji.domain.blank? }
  end

  def emojis_from_identities
    rows = Array(emoji_identities)
    return [] if rows.empty?

    local_ids = rows.filter_map { |row| identity_value(row, 'id') if identity_value(row, 'domain').blank? }
    found_local = CustomEmoji.local.where(id: local_ids).index_by { |emoji| emoji.id.to_s }

    rows.filter_map do |row|
      domain = identity_value(row, 'domain').presence
      shortcode = identity_value(row, 'shortcode')
      next if shortcode.blank?

      if domain
        CustomEmoji.find_by(domain: domain, shortcode: shortcode)
      else
        found_local[identity_value(row, 'id').to_s]
      end
    end
  end

  def identity_value(row, key)
    return if row.blank?

    row[key] || row[key.to_sym]
  end
end
