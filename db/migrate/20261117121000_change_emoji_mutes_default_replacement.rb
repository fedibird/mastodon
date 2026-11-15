# frozen_string_literal: true

class ChangeEmojiMutesDefaultReplacement < ActiveRecord::Migration[6.1]
  def change
    change_column_default :emoji_mutes, :replacement, from: '［絵文字］', to: '◻'
  end
end
