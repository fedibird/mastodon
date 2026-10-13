# frozen_string_literal: true

class AddPostTitleAndApObjectTypeToStatuses < ActiveRecord::Migration[6.1]
  # PostgreSQL 11+ adds a nullable column with no default as a catalog
  # update. PostgreSQL 16 on this deployment does not rewrite existing
  # status rows for that change. There is intentionally no column default
  # and no UPDATE: existing rows stay NULL, and the application reads a
  # NULL ap_object_type as "note".
  #
  # char_length is Unicode code points and matches Status::POST_TITLE_MAX_CODEPOINTS (100).
  # The check is NOT VALID. PostgreSQL then enforces it for later inserts
  # and updates without scanning rows already in the table. Do not validate
  # it in this release; validation would share-lock and read the whole
  # statuses table. Rails 6.1 schema dumps omit `validate: false`, so a
  # populated database must take this migration rather than schema:load.
  def change
    # strong_migrations rejects change_table, so these stay separate adds.
    add_column :statuses, :post_title, :text # rubocop:disable Rails/BulkChangeTable
    add_column :statuses, :ap_object_type, :string # rubocop:enable Rails/BulkChangeTable

    add_check_constraint :statuses, <<~SQL.squish, name: 'statuses_post_title_shape', validate: false
      (ap_object_type IS NULL OR ap_object_type IN ('note', 'page'))
      AND (
        post_title IS NULL
        OR (
          char_length(post_title) BETWEEN 1 AND 100
          AND post_title !~ '[[:cntrl:]]'
          AND btrim(post_title) <> ''
        )
      )
      AND (ap_object_type IS DISTINCT FROM 'page' OR post_title IS NOT NULL)
    SQL
  end
end
