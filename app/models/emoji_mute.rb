# frozen_string_literal: true

# == Schema Information
#
# Table name: emoji_mutes
#
#  id                             :bigint(8)        not null, primary key
#  user_id                        :bigint(8)        not null
#  kind                           :string           not null
#  native                         :text
#  custom_emoji_id                :bigint(8)
#  domain                         :string
#  shortcode                      :string
#  replace_in_text                :boolean          default(TRUE), not null
#  reject_reactions_to_own_posts  :boolean          default(TRUE), not null
#  hide_reactions                 :boolean          default(TRUE), not null
#  hide_in_picker                 :boolean          default(TRUE), not null
#  replacement                    :string           default("◻"), not null
#  revision                       :bigint(8)        default(1), not null
#  created_at                     :datetime         not null
#  updated_at                     :datetime         not null
#
class EmojiMute < ApplicationRecord
  EFFECTS = %w(
    replace_in_text
    reject_reactions_to_own_posts
    hide_reactions
    hide_in_picker
  ).freeze

  # Server reads apply the reaction effects below. The WebUI applies
  # replace_in_text as a display projection and does not rewrite status HTML,
  # so it stays in STORED_ONLY_EFFECTS. hide_in_picker stays stored.
  APPLIED_EFFECTS = %w(reject_reactions_to_own_posts hide_reactions).freeze
  STORED_ONLY_EFFECTS = %w(replace_in_text hide_in_picker).freeze

  DEFAULT_REPLACEMENT = '◻'
  MAX_PER_USER = 500
  MAX_REPLACEMENT_GRAPHEMES = 32
  MAX_REPLACEMENT_BYTES = 256
  MAX_BODY_BYTES = 512 * 1024

  belongs_to :user

  def reference
    case kind
    when 'unicode'
      { 'kind' => 'unicode', 'native' => native }
    when 'local'
      { 'kind' => 'custom', 'scope' => 'local', 'custom_emoji_id' => custom_emoji_id.to_s, 'shortcode' => shortcode }
    else
      { 'kind' => 'custom', 'scope' => 'remote', 'domain' => domain, 'shortcode' => shortcode }
    end
  end

  def effects
    EFFECTS.index_with { |name| public_send(name) }
  end
end
