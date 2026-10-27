# frozen_string_literal: true

# Article URL digest for a generation that is still moving (issue #588, P3-A).
#
# Nullable and without a default, so PostgreSQL 11+ does not rewrite existing
# external_media_assets rows. No backfill: a row created before a swap keeps
# resolving through url_digest. logical_digest is set only on the incoming
# generation.
class AddExternalMediaLogicalDigest < ActiveRecord::Migration[6.1]
  disable_ddl_transaction!

  def up
    safety_assured do
      execute "SET lock_timeout = '5s'"
      add_column :external_media_assets, :logical_digest, :string
    end
  end

  def down
    safety_assured do
      execute "SET lock_timeout = '5s'"
      remove_column :external_media_assets, :logical_digest
    end
  end
end
