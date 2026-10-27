# frozen_string_literal: true

# Per-URL attempt notes for one logical RSS image (issue #588, P3-C).
#
# Nullable fingerprint and a constant jsonb default. PostgreSQL 11+ does not
# rewrite existing external_media_assets rows for that default. The log stores
# digests and error codes only. It does not store URLs.
class AddExternalMediaAttemptLog < ActiveRecord::Migration[6.1]
  disable_ddl_transaction!

  def up
    safety_assured do
      execute "SET lock_timeout = '5s'"
      add_column :external_media_assets, :candidate_fingerprint, :string
      add_column :external_media_assets, :attempt_log, :jsonb, null: false, default: []
    end
  end

  def down
    safety_assured do
      execute "SET lock_timeout = '5s'"
      remove_column :external_media_assets, :attempt_log
      remove_column :external_media_assets, :candidate_fingerprint
    end
  end
end
