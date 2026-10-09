# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PostingIdentity::Local do
  let(:user) { Fabricate(:user, account: Fabricate(:account, username: 'ada', display_name: 'Ada')) }

  def identity
    described_class.new(user.reload)
  end

  it 'is ready for a functional account that is allowed to post' do
    expect(identity.id).to eq "local:#{user.account_id}"
    expect(identity.kind).to eq 'local'
    expect(identity.provider).to eq 'fedibird'
    expect(identity.authorization).to eq 'ready'
    expect(identity).to be_postable
    expect(identity.capabilities).to include(
      'post' => 'supported',
      'media' => 'supported',
      'reply' => 'supported',
      'group' => 'supported',
      'schedule' => 'supported'
    )
  end

  it 'does not mark a suspended account ready' do
    user.account.update!(suspended_at: Time.now.utc)

    expect(identity.authorization).to eq 'unavailable'
    expect(identity).not_to be_postable
    expect(identity.capabilities.values).to all(eq('unavailable'))
  end

  it 'does not mark a disabled account ready' do
    user.update!(disabled: true)

    expect(identity.authorization).to eq 'unavailable'
    expect(identity).not_to be_postable
  end

  it 'does not mark an unapproved account ready' do
    user.update!(approved: false)

    expect(identity.authorization).to eq 'unavailable'
    expect(identity).not_to be_postable
  end

  it 'does not ignore setting_disable_post' do
    user.settings.disable_post = true

    expect(identity.authorization).to eq 'restricted'
    expect(identity).not_to be_postable
    expect(identity.capabilities['post']).to eq 'unavailable'
    expect(identity.capabilities['media']).to eq 'unavailable'
  end
end
