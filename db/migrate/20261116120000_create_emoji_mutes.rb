# frozen_string_literal: true

class CreateEmojiMutes < ActiveRecord::Migration[6.1]
  def change
    create_table :emoji_mute_collections do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.bigint :revision, null: false, default: 0
      t.timestamps
    end

    create_table :emoji_mutes do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :kind, null: false
      t.text :native
      t.bigint :custom_emoji_id
      t.string :domain
      t.string :shortcode
      t.boolean :replace_in_text, null: false, default: true
      t.boolean :reject_reactions_to_own_posts, null: false, default: true
      t.boolean :hide_reactions, null: false, default: true
      t.boolean :hide_in_picker, null: false, default: true
      t.string :replacement, null: false, default: '［絵文字］'
      t.bigint :revision, null: false, default: 1
      t.timestamps
      t.check_constraint <<~SQL.squish, name: 'emoji_mutes_identity_shape'
        (kind = 'unicode' AND native IS NOT NULL AND custom_emoji_id IS NULL AND domain IS NULL AND shortcode IS NULL)
        OR (kind = 'local' AND native IS NULL AND custom_emoji_id IS NOT NULL AND domain IS NULL)
        OR (kind = 'remote' AND native IS NULL AND custom_emoji_id IS NULL AND domain IS NOT NULL AND shortcode IS NOT NULL)
      SQL
    end

    add_index :emoji_mutes, [:user_id, :native], unique: true, where: "kind = 'unicode'", name: 'index_emoji_mutes_unicode_identity'
    add_index :emoji_mutes, [:user_id, :custom_emoji_id], unique: true, where: "kind = 'local'", name: 'index_emoji_mutes_local_identity'
    add_index :emoji_mutes, [:user_id, :domain, :shortcode], unique: true, where: "kind = 'remote'", name: 'index_emoji_mutes_remote_identity'
  end
end
