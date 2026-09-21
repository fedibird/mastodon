# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ActionReview::PolicySettings do
  def stub_policies(value)
    allow(Setting).to receive(:[]).and_wrap_original do |method, key|
      key.to_s == 'action_review_policies' ? value : method.call(key)
    end
  end

  it 'defaults every registered operation to off' do
    ActionReview::OperationRegistry::OPERATIONS.each_key do |key|
      expect(described_class.mode_for(key)).to eq 'off'
    end
    expect(Setting['action_review_policies']).to include(
      'follow_import' => 'off',
      'account_migration' => 'off',
      'invite_creation' => 'off',
      'status_import' => 'off'
    )
  end

  it 'reads a configured valid policy' do
    stub_policies(
      'follow_import' => 'medium',
      'account_migration' => 'always'
    )

    expect(described_class.mode_for('follow_import')).to eq 'medium'
    expect(described_class.mode_for('account_migration')).to eq 'always'
  end

  it 'falls back to off when a registered key is missing from the hash' do
    stub_policies('follow_import' => 'high')

    expect(described_class.mode_for('invite_creation')).to eq 'off'
  end

  it 'treats an unrecognized configured mode as always so a typo cannot disable review' do
    stub_policies('follow_import' => 'dangerous')

    expect(described_class.mode_for('follow_import')).to eq 'always'
  end

  it 'treats a non-hash setting blob as always' do
    stub_policies('off')

    expect(described_class.mode_for('follow_import')).to eq 'always'
  end

  it 'does not silently accept an unknown operation' do
    expect { described_class.mode_for('widget_import') }
      .to raise_error(ActionReview::OperationRegistry::UnknownOperation)
  end

  it 'does not disturb Setting hash initialization or Form::AdminSettings' do
    expect(Setting.default_settings['action_review_policies']).to include(
      'follow_import' => 'off',
      'account_migration' => 'off',
      'invite_creation' => 'off',
      'status_import' => 'off'
    )
    expect { Form::AdminSettings.new }.not_to raise_error
  end

  it 'exposes supported modes for later Admin UI' do
    expect(described_class.supported_modes_for('follow_import')).to eq %w(off high medium low always)
    expect(described_class.supported_modes_for('invite_creation')).to eq %w(off always)
  end
end
