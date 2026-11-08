# frozen_string_literal: true

# == Schema Information
#
# Table name: emoji_mute_collections
#
#  id         :bigint(8)        not null, primary key
#  user_id    :bigint(8)        not null
#  revision   :bigint(8)        default(0), not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
class EmojiMuteCollection < ApplicationRecord
  belongs_to :user
end
