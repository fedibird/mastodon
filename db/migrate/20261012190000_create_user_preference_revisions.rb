# frozen_string_literal: true

class CreateUserPreferenceRevisions < ActiveRecord::Migration[6.1]
  def up
    create_table :user_preference_revisions, id: false do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: false, type: :bigint
      t.bigint :revision, null: false
    end
    # The table is empty. This primary key does not rewrite users.
    safety_assured { execute 'ALTER TABLE user_preference_revisions ADD PRIMARY KEY (user_id)' }
  end

  def down
    drop_table :user_preference_revisions
  end
end
