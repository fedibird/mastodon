# frozen_string_literal: true

class EnlargePostDraftsPayloadCheck < ActiveRecord::Migration[6.1]
  # Matches PostDrafts::Payload::MAX_BYTES. The original 32 KiB check cannot
  # hold a 10,000-character P0 snapshot once content_hash repeats the input.
  # 256 KiB does. A snapshot that only fits by filling every field cap is
  # rejected by the application before insert.
  #
  # The replacement is NOT VALID here. The next migration validates it.
  # post_drafts is a new table and is empty when these migrations run.
  # Down puts the 32 KiB check back as NOT VALID and does not delete or
  # rewrite rows. A draft already stored above 32 KiB stays until that row
  # is updated. After any such row exists, roll forward; rolling back does
  # not shrink stored drafts.
  LIMIT = 262_144
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
