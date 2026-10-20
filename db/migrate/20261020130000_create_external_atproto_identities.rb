# frozen_string_literal: true

# Owner-scoped AT Protocol connection metadata and single-use OAuth attempts.
# Reversible: `change` drops both tables. No statuses index and no public seed.
class CreateExternalAtprotoIdentities < ActiveRecord::Migration[6.1]
  def change
    create_table :external_identities do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :provider, null: false, limit: 64
      t.string :subject, null: false, limit: 2048
      t.string :issuer, null: false, limit: 512
      t.string :resource_origin, null: false, limit: 512
      t.string :handle, limit: 253
      t.string :display_name, limit: 200
      t.references :credential, foreign_key: { to_table: :user_external_credentials, on_delete: :nullify }, index: true
      t.string :granted_scopes, array: true, null: false, default: []
      t.datetime :disconnected_at
      t.string :terms_state, null: false, limit: 32, default: 'unreviewed'
      t.string :status, null: false, limit: 64, default: 'connected'
      t.datetime :session_bound_at
      t.bigint :bound_attempt_id
      t.datetime :last_checked_at
      t.string :last_error_code, limit: 64
      t.string :revocation_state, limit: 64
      t.string :token_endpoint, null: false, limit: 512
      t.string :revocation_endpoint, limit: 512
      t.integer :refresh_generation, null: false, default: 0
      t.datetime :refresh_started_at
      t.datetime :access_expires_at

      t.timestamps
    end

    add_index :external_identities, [:user_id, :provider, :subject], unique: true, name: 'index_external_identities_on_owner_provider_subject'
    add_index :external_identities, :user_id

    create_table :external_oauth_attempts do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: true
      t.string :provider, null: false, limit: 64, default: 'bluesky'
      t.string :state_digest, null: false, limit: 64
      t.string :browser_binding_digest, null: false, limit: 64
      t.string :input_kind, null: false, limit: 32
      t.string :login_hint, limit: 512
      t.string :intended_subject, limit: 2048
      t.string :issuer, null: false, limit: 512
      t.string :resource_origin, limit: 512
      t.string :authorization_endpoint, null: false, limit: 512
      t.string :token_endpoint, null: false, limit: 512
      t.string :par_endpoint, null: false, limit: 512
      t.string :revocation_endpoint, limit: 512
      t.string :redirect_uri, null: false, limit: 512
      t.string :requested_scopes, null: false, limit: 1024
      t.string :dpop_nonce, limit: 512
      t.string :binding_id, null: false, limit: 36
      t.text :encrypted_secrets, null: false
      t.string :encryption_key_id, null: false, limit: 32
      t.datetime :expires_at, null: false
      t.datetime :consumed_at

      t.timestamps
    end

    add_index :external_oauth_attempts, :state_digest, unique: true
  end
end
