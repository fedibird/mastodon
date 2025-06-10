# frozen_string_literal: true

require Rails.root.join('lib', 'mastodon', 'migration_helpers')

class AddReadingToCustomEmoji < ActiveRecord::Migration[6.1]
  include Mastodon::MigrationHelpers

  disable_ddl_transaction!

  def up
    safety_assured { add_column_with_default :custom_emojis, :reading, :string, collation: 'ja-x-icu', default: '', allow_null: false }
    CustomEmoji.local.find_each do |emoji|
      emoji.aliases.compact_blank!
      emoji.reading = emoji.ruby.presence || emoji.aliases.find { |k| k&.kana? } || emoji.shortcode.hiragana
      emoji.record_timestamps = false
      emoji.save
    end
    safety_assured { add_index :custom_emojis, :reading, where: 'domain is null and disabled = false and visible_in_picker', algorithm: :concurrently, name: :index_custom_emoji_on_reading }
  end

  def down
    remove_column :custom_emojis, :reading
  end
end
