# frozen_string_literal: true

# == Schema Information
#
# Table name: emoji_mutes
#
#  id                            :bigint(8)        not null, primary key
#  account_id                    :bigint(8)        not null
#  kind                          :string           not null
#  native                        :string
#  custom_emoji_id               :bigint(8)
#  domain                        :string
#  shortcode                     :string
#  replace_in_text               :boolean          default(TRUE), not null
#  reject_reactions_to_own_posts :boolean          default(TRUE), not null
#  hide_reactions                :boolean          default(TRUE), not null
#  hide_in_picker                :boolean          default(TRUE), not null
#  replacement                   :string           default("［絵文字］"), not null
#  revision                      :integer          default(1), not null
#  created_at                    :datetime         not null
#  updated_at                    :datetime         not null
#

class EmojiMute < ApplicationRecord
  belongs_to :account

  validates :kind, inclusion: { in: %w(unicode local remote) }
  validates :revision, numericality: { only_integer: true, greater_than: 0 }

  def self.matching_identity(account_id, identity)
    scope = where(account_id: account_id, kind: identity.kind)
    case identity.kind
    when 'unicode'
      scope.where(native: identity.native)
    when 'local'
      scope.where(custom_emoji_id: identity.custom_emoji_id)
    else
      scope.where(domain: identity.domain, shortcode: identity.shortcode)
    end
  end
end
