# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DeepLCredentialSettings, type: :service do
  let(:user) { Fabricate(:user) }
  let(:settings) { described_class.new(user) }
  let(:api_key) { 'personal-deepl-key-without-fx' }

  def deepl_rows
    described_class.scope_for(user).order(:id).to_a
  end

  describe 'save!' do
    it 'stores a new credential inside the user lock and does not call DeepL' do
      inside_lock = false

      with_vault_keyring do
        allow(user).to receive(:with_lock).and_wrap_original do |method, *args, &block|
          method.call(*args) do
            inside_lock = true
            block.call
          ensure
            inside_lock = false
          end
        end
        allow(UserCredentialVault).to receive(:store!).and_wrap_original do |method, **kwargs|
          expect(inside_lock).to be(true)
          method.call(**kwargs)
        end
        expect(UserCredentialVault).not_to receive(:replace!)

        expect { settings.save!("  #{api_key}  ") }.to change { deepl_rows.size }.from(0).to(1)

        row = deepl_rows.first
        expect(row.provider).to eq('deepl')
        expect(row.purpose).to eq('translation')
        expect(row.credential_type).to eq('api_key')
        expect(row.display_name).to eq('DeepL')
        expect(probe_vault(owner: user, credential: row)[:result]).to eq(api_key)
        expect(WebMock).not_to have_requested(:any, /deepl\.com/)
      end
    end

    it 'replaces the only row, changes binding_id, and clears revoked_at and expires_at' do
      inside_lock = false

      with_vault_keyring do
        existing = store_vault_credential(owner: user, secret: 'old-personal-deepl-key')
        previous_binding = existing.binding_id
        existing.update!(revoked_at: 1.hour.ago, expires_at: 1.hour.ago)

        allow(user).to receive(:with_lock).and_wrap_original do |method, *args, &block|
          method.call(*args) do
            inside_lock = true
            block.call
          ensure
            inside_lock = false
          end
        end
        allow(UserCredentialVault).to receive(:replace!).and_wrap_original do |method, **kwargs|
          expect(inside_lock).to be(true)
          expect(kwargs[:revoked_at]).to be_nil
          expect(kwargs[:expires_at]).to be_nil
          expect(kwargs[:provider]).to eq('deepl')
          expect(kwargs[:purpose]).to eq('translation')
          expect(kwargs[:credential_type]).to eq('api_key')
          method.call(**kwargs)
        end
        expect(UserCredentialVault).not_to receive(:store!)

        settings.save!(api_key)

        existing.reload
        expect(deepl_rows.map(&:id)).to eq([existing.id])
        expect(existing.binding_id).not_to eq(previous_binding)
        expect(existing.revoked_at).to be_nil
        expect(existing.expires_at).to be_nil
        expect(existing.provider).to eq('deepl')
        expect(probe_vault(owner: user, credential: existing)[:result]).to eq(api_key)
        expect(WebMock).not_to have_requested(:any, /deepl\.com/)
      end
    end

    it 'fails closed when more than one matching row exists' do
      with_vault_keyring do
        rows = Array.new(2) { store_vault_credential(owner: user, secret: "dup-#{SecureRandom.hex(8)}") }
        bindings = rows.map(&:binding_id)

        expect(UserCredentialVault).not_to receive(:store!)
        expect(UserCredentialVault).not_to receive(:replace!)
        expect { settings.save!(api_key) }.to raise_error(described_class::Ambiguous)
        expect(deepl_rows.map(&:binding_id)).to eq(bindings)
      end
    end

    it 'refuses to save when the vault keyring is unavailable and does not include the key in the error' do
      with_vault_keyring(primary: '', keys: '') do
        expect { settings.save!(api_key) }.to raise_error(described_class::Unavailable) { |error|
          expect(error.message).not_to include(api_key)
        }
        expect(deepl_rows).to be_empty
      end
    end

    it 'rejects blank, control characters, overlong, and non-string keys without echoing them' do
      with_vault_keyring do
        ['', '   ', "line\nbreak", "line\rbreak", "#{api_key}\n", "#{api_key}\r\n", "null\u0000byte", "delete\u007F", 'a' * 513, ['array-key'], { api_key: 'hash' }].each do |bad|
          expect { settings.save!(bad) }.to raise_error(described_class::InvalidKey) { |error|
            expect(error.message).not_to include('line')
            expect(error.message).not_to include('array-key')
            expect(error.message).not_to include('a' * 32)
          }
        end
        expect(deepl_rows).to be_empty
        expect { settings.save!('a' * 512) }.not_to raise_error
      end
    end

    it 'turns a persistence failure into SaveFailed without keeping the key in the error' do
      with_vault_keyring do
        allow(UserCredentialVault).to receive(:store!).and_raise(ActiveRecord::RecordNotSaved.new("could not save #{api_key}"))

        expect { settings.save!(api_key) }.to raise_error(described_class::SaveFailed) { |error|
          expect(error.message).not_to include(api_key)
          expect(error.cause).to be_nil
        }
        expect(deepl_rows).to be_empty
      end
    end

    it 'turns a replace lifecycle failure into SaveFailed without keeping the key in the error' do
      with_vault_keyring do
        store_vault_credential(owner: user, secret: 'old-personal-deepl-key')
        allow(UserCredentialVault).to receive(:replace!).and_raise(ActiveRecord::RecordNotFound.new("missing #{api_key}"))

        expect { settings.save!(api_key) }.to raise_error(described_class::SaveFailed) { |error|
          expect(error.message).not_to include(api_key)
          expect(error.cause).to be_nil
        }
        expect(deepl_rows.size).to eq(1)
        expect(probe_vault(owner: user, credential: deepl_rows.first)[:result]).to eq('old-personal-deepl-key')
      end
    end
  end

  describe 'delete!' do
    it 'deletes only the owner classification match without decrypting' do
      with_vault_keyring do
        row = store_vault_credential(owner: user, secret: api_key)
        other = store_vault_credential(owner: Fabricate(:user), secret: 'other-user-deepl-key')
        other_kind = store_vault_credential(owner: user, secret: 'github-token-value', provider: 'github', purpose: 'login', credential_type: 'token')

        expect(UserCredentialVault::Cipher).not_to receive(:decrypt)
        expect(UserCredentialVault).not_to receive(:with_credential)

        settings.delete!(row.id)

        expect(UserExternalCredential.find_by(id: row.id)).to be_nil
        expect(other.reload).to be_persisted
        expect(other_kind.reload).to be_persisted
        expect(WebMock).not_to have_requested(:any, /deepl\.com/)
      end
    end

    it 'deletes when the keyring is missing' do
      row = with_vault_keyring { store_vault_credential(owner: user, secret: api_key) }

      with_vault_keyring(primary: '', keys: '') do
        expect(UserCredentialVault::Cipher).not_to receive(:decrypt)
        settings.delete!(row.id)
        expect(UserExternalCredential.find_by(id: row.id)).to be_nil
      end
    end

    it 'does not reveal another user credential id' do
      row = with_vault_keyring { store_vault_credential(owner: Fabricate(:user), secret: api_key) }

      expect { settings.delete!(row.id) }.to raise_error(ActiveRecord::RecordNotFound)
      expect(row.reload).to be_persisted
    end
  end

  describe 'concurrent save' do
    self.use_transactional_tests = false

    it 'keeps a single row when two saves overlap' do
      user_id = nil
      account_id = nil

      with_vault_keyring do
        owner = Fabricate(:user)
        user_id = owner.id
        account_id = owner.account_id
        started = Queue.new

        threads = Array.new(2) do |index|
          Thread.new do
            ActiveRecord::Base.connection_pool.with_connection do
              started << index
              sleep 0.01 while started.size < 2
              described_class.new(User.find(user_id)).save!("concurrent-deepl-key-#{index}-#{SecureRandom.hex(4)}")
            end
          end
        end
        threads.each(&:join)

        expect(UserExternalCredential.where(user_id: user_id, provider: 'deepl', purpose: 'translation', credential_type: 'api_key').count).to eq(1)
        expect(WebMock).not_to have_requested(:any, /deepl\.com/)
      end
    ensure
      UserExternalCredential.where(user_id: user_id).delete_all if user_id
      User.where(id: user_id).delete_all if user_id
      Account.where(id: account_id).delete_all if account_id
    end
  end
end
