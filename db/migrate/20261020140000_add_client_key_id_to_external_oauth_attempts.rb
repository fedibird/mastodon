# frozen_string_literal: true

# Records the confidential-client signing key that attested PAR.
# Callback and later refresh keep using that key. Reversible.
class AddClientKeyIdToExternalOauthAttempts < ActiveRecord::Migration[6.1]
  def up
    add_column :external_oauth_attempts, :client_key_id, :string, limit: 128, null: false, default: 'retired'
    # Existing draft attempts were not bound to a PAR key. `retired` matches
    # no configured key, so the callback refuses them instead of switching keys.
    safety_assured { change_column_default :external_oauth_attempts, :client_key_id, from: 'retired', to: nil }
  end

  def down
    remove_column :external_oauth_attempts, :client_key_id
  end
end
