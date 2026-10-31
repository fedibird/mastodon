# frozen_string_literal: true

# Explicit directory language tags. The check is a limited BCP 47 subset:
# a 2–3 letter primary subtag and at most three subtags of 2–8 letters or
# digits (ja, en-US, zh-Hans). It is not every well-formed BCP 47 tag.
# NodeInfo languages, the viewer's locale, and post languages are not copied
# here. Group creation requests stay a review snapshot and do not gain a
# language column. The P2 management screen (#674 P2-B) writes this table
# through GroupDirectory::Languages.replace!.
class CreateGroupLanguages < ActiveRecord::Migration[6.1]
  TAG_CHECK = "tag ~ '^[a-z]{2,3}(-[0-9A-Za-z]{2,8}){0,3}$'"

  def change
    create_table :group_languages do |t|
      t.references :account, null: false, foreign_key: { to_table: :accounts, on_delete: :cascade }, index: false
      t.string :tag, null: false, limit: 35
      t.timestamps
    end

    add_index :group_languages, [:account_id, :tag],
              unique: true,
              name: 'index_group_languages_on_account_id_and_tag'
    add_index :group_languages, :tag, name: 'index_group_languages_on_tag'
    add_check_constraint :group_languages, TAG_CHECK, name: 'group_languages_tag_shape'
  end
end
