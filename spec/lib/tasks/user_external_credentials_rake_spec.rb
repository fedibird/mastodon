require 'rails_helper'
require 'rake'

RSpec.describe 'user_external_credentials rake tasks' do
  before(:all) do
    Rails.application.load_tasks
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  def invoke(name)
    task = Rake::Task[name]
    task.reenable
    task.invoke
  end

  it 'previews and rotates without printing the credential' do
    user = Fabricate(:user)
    record = with_vault_keyring(primary: 'v1') { store_vault_credential(owner: user) }

    preview = nil
    with_vault_keyring(primary: 'v2') do
      ClimateControl.modify(DRY_RUN: '1') do
        preview = capture_stdout { invoke('user_external_credentials:rotate') }
      end
    end

    expect(preview).to include('mode=dry_run')
    expect(preview).to include('rotated=0')
    expect(preview).to include('would_rotate=1')
    expect(preview).not_to include(vault_secret)
    expect(record.reload.encryption_key_id).to eq('v1')

    written = nil
    with_vault_keyring(primary: 'v2') do
      written = capture_stdout { invoke('user_external_credentials:rotate') }
      counts = capture_stdout { invoke('user_external_credentials:key_counts') }
      expect(counts).to include('encryption_key_id=v2 count=1')
      expect(counts).not_to include(vault_secret)
    end

    expect(written).to include('mode=write')
    expect(written).to include('rotated=1')
    expect(written).not_to include(vault_secret)
    expect(record.reload.encryption_key_id).to eq('v2')
  end

  it 'prints a visible failure and keeps the unreadable row' do
    user = Fabricate(:user)
    record = with_vault_keyring(primary: 'v1') { store_vault_credential(owner: user) }
    record.update_columns(encrypted_payload: tamper_ciphertext(record.encrypted_payload))
    ciphertext = record.encrypted_payload

    output = +''
    expect do
      with_vault_keyring(primary: 'v2') do
        original = $stdout
        buffer = StringIO.new
        $stdout = buffer
        begin
          invoke('user_external_credentials:rotate')
        ensure
          $stdout = original
          output = buffer.string
        end
      end
    end.to raise_error(UserCredentialVault::RotationError)

    expect(output).to include("failure id=#{record.id}")
    expect(output).to include('error=UserCredentialVault::AuthenticationFailure')
    expect(output).not_to include(vault_secret)
    expect(output).not_to include(ciphertext)
    expect(UserExternalCredential.find(record.id).encrypted_payload).to eq(ciphertext)
  end
end
