# frozen_string_literal: true

# Supports bounded deletion of consumed tombstones and expired open attempts.
# Reversible: drops both indexes.
class IndexExternalOauthAttemptsForCleanup < ActiveRecord::Migration[6.1]
  def change
    safety_assured do
      add_index :external_oauth_attempts, :expires_at,
                where: 'consumed_at IS NULL',
                name: :index_external_oauth_attempts_on_open_expires_at
      add_index :external_oauth_attempts, :id,
                where: 'consumed_at IS NOT NULL',
                name: :index_external_oauth_attempts_on_consumed_id
    end
  end
end
