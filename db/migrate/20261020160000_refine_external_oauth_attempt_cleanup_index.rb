# frozen_string_literal: true

# Consumed tombstones are deleted by created_at and consumed_at, not by id.
# Reversible: restores the previous partial index on consumed ids.
class RefineExternalOauthAttemptCleanupIndex < ActiveRecord::Migration[6.1]
  def up
    safety_assured do
      remove_index :external_oauth_attempts, name: :index_external_oauth_attempts_on_consumed_id
      add_index :external_oauth_attempts, [:created_at, :consumed_at],
                where: 'consumed_at IS NOT NULL',
                name: :index_external_oauth_attempts_on_consumed_age
    end
  end

  def down
    safety_assured do
      remove_index :external_oauth_attempts, name: :index_external_oauth_attempts_on_consumed_age
      add_index :external_oauth_attempts, :id,
                where: 'consumed_at IS NOT NULL',
                name: :index_external_oauth_attempts_on_consumed_id
    end
  end
end
