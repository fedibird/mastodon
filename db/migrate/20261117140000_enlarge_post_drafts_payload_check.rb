# frozen_string_literal: true

class EnlargePostDraftsPayloadCheck < ActiveRecord::Migration[6.1]
  # Matches PostDrafts::Payload::MAX_BYTES. A full content_hash repeats the
  # input, so the original 32 KiB check cannot hold a draft the field caps
  # already allow.
  #
  # Up replaces that check with the larger one. Rows stored under the old
  # check already fit, so there is nothing to scan. The replacement is NOT
  # VALID: PostgreSQL enforces it for later inserts without reading the
  # table. Down restores the 32 KiB check the same way, so a row already
  # stored above 32 KiB stays until that row is updated. Rails 6.1 schema
  # dumps omit validate: false.
  LIMIT = 2_343_186
  PREVIOUS_LIMIT = 32_768

  SHAPE = <<~SQL.squish.freeze
    client_uuid ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    AND schema_version = 1
    AND revision >= 1
    AND state = 'active'
    AND octet_length(payload::text) <= %d
  SQL

  def up
    safety_assured { execute "SET LOCAL lock_timeout = '5s'" }
    remove_check_constraint :post_drafts, name: 'post_drafts_shape'
    add_check_constraint :post_drafts, format(SHAPE, LIMIT), name: 'post_drafts_shape', validate: false
  end

  def down
    safety_assured { execute "SET LOCAL lock_timeout = '5s'" }
    remove_check_constraint :post_drafts, name: 'post_drafts_shape'
    add_check_constraint :post_drafts, format(SHAPE, PREVIOUS_LIMIT), name: 'post_drafts_shape', validate: false
  end
end
