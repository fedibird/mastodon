require 'rails_helper'

RSpec.describe UserExternalCredential, type: :model do
  describe 'lifecycle' do
    it 'destroys credential rows when the user is destroyed' do
      user = Fabricate(:user)
      with_vault_keyring do
        store_vault_credential(owner: user)
        expect { user.destroy! }.to change(described_class, :count).from(1).to(0)
      end
    end

    it 'declares a NOT NULL user_id foreign key with ON DELETE CASCADE' do
      column = described_class.columns_hash.fetch('user_id')
      foreign_key = described_class.connection.foreign_keys(described_class.table_name).find { |key| key.to_table == 'users' }
      reflection = User.reflect_on_association(:external_credentials)

      expect(column.null).to be(false)
      expect(foreign_key.column).to eq('user_id')
      expect(foreign_key.on_delete).to eq(:cascade)
      expect(reflection.klass).to eq(described_class)
      expect(reflection.options[:dependent]).to eq(:destroy)
    end
  end

  describe 'plain columns' do
    it 'rejects plaintext, control characters, and in-place classification changes' do
      record = with_vault_keyring { store_vault_credential(owner: Fabricate(:user), display_name: 'label') }

      record.display_name = "bad\nname"
      expect(record).not_to be_valid

      record.reload
      record.provider = 'libre'
      expect(record).not_to be_valid
      expect(record.reload.provider).to eq('deepl')

      record.encrypted_payload = '{"api_key":"plaintext"}'
      expect(record).not_to be_valid

      expect(described_class.column_names).not_to include('metadata')
    end
  end
end
