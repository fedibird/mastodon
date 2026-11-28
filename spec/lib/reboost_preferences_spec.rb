# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ReboostPreferences do
  it 'follows the acceptance policy only while the choice is unset' do
    expect(described_class.enabled?(nil, 'conservative')).to be false
    expect(described_class.enabled?(nil, 'default')).to be true
    expect(described_class.enabled?(nil, 'tester')).to be true
    expect(described_class.enabled?(false, 'tester')).to be false
    expect(described_class.enabled?(true, 'conservative')).to be true
    expect(described_class.choice(nil)).to eq 'auto'
    expect(described_class.choice(true)).to eq 'on'
    expect(described_class.choice(false)).to eq 'off'
    expect(described_class.normalize_choice('nope')).to eq :invalid
  end

  it 'follows a policy change only while the stored choice is unset' do
    user = Fabricate(:user)
    user.settings.new_features_policy = 'conservative'
    value = UserPreferences::Reader.new(user).get('enable_reboost')

    expect(value.configured).to be_nil
    expect(value.effective).to be false

    user.settings.enable_reboost = true
    user.settings.new_features_policy = 'default'
    explicit = UserPreferences::Reader.new(user).get('enable_reboost')

    expect(explicit.configured).to be true
    expect(explicit.effective).to be true
  end
end
