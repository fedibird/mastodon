# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ActionReview::OperationRegistry do
  it 'resolves registered operations' do
    expect(described_class.keys).to contain_exactly(
      'follow_import',
      'account_migration',
      'invite_creation',
      'status_import'
    )
    expect(described_class.registered?('follow_import')).to be true
    expect(described_class.fetch!('follow_import')).to eq(automated_signal: true)
  end

  it 'reports automated signal support only for follow_import' do
    expect(described_class.automated_signal?('follow_import')).to be true
    expect(described_class.automated_signal?('account_migration')).to be false
    expect(described_class.automated_signal?('invite_creation')).to be false
    expect(described_class.automated_signal?('status_import')).to be false
  end

  it 'fails explicitly for an unknown operation' do
    expect { described_class.fetch!('moderation_suspend') }
      .to raise_error(ActionReview::OperationRegistry::UnknownOperation, /unknown action review operation/)
    expect { described_class.automated_signal?('nope') }
      .to raise_error(ActionReview::OperationRegistry::UnknownOperation)
  end

  it 'exposes supported policy modes for UI' do
    expect(described_class.supported_policy_modes('follow_import')).to eq %w(off high medium low always)
    expect(described_class.supported_policy_modes('account_migration')).to eq %w(off always)
    expect(described_class.supported_policy_modes('invite_creation')).to eq %w(off always)
    expect(described_class.supported_policy_modes('status_import')).to eq %w(off always)
  end
end
