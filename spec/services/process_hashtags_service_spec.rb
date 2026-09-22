# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ProcessHashtagsService, type: :service do
  let(:account) { Fabricate(:account, username: 'alice') }

  it 'sets a time-limit expiry while creating tags' do
    status = Fabricate(:status, account: account, text: 'hello #kept #exp1h')

    described_class.new.call(status)

    expect(status.tags.pluck(:name)).to include('kept', 'exp1h')
    expect(status.status_expire).to be_present
    expect(status.status_expire.expires_mark?).to be true
  end

  it 'replaces tags on edit without changing the existing expiry' do
    status = Fabricate(:status, account: account, text: 'hello #kept #exp1h')
    described_class.new.call(status)
    expire = status.status_expire
    expires_at = expire.expires_at

    status.update!(text: 'hello #kept #added')
    described_class.new.call(status, [], replace: true)

    status.reload
    expect(status.tags.pluck(:name)).to contain_exactly('kept', 'added')
    expect(status.status_expire.id).to eq expire.id
    expect(status.status_expire.expires_at).to be_within(1.second).of(expires_at)
    expect(status.status_expire.action).to eq 'mark'
  end

  it 'does not create an expiry when an edit adds a time-limit hashtag' do
    status = Fabricate(:status, account: account, text: 'hello #kept')
    described_class.new.call(status)
    expect(status.status_expire).to be_nil

    status.update!(text: 'hello #kept #exp1h')
    described_class.new.call(status, [], replace: true)

    expect(status.reload.tags.pluck(:name)).to include('exp1h')
    expect(status.status_expire).to be_nil
  end

  it 'does not change expires_at when an edit swaps the time-limit hashtag' do
    status = Fabricate(:status, account: account, text: 'hello #exp1h')
    described_class.new.call(status)
    expires_at = status.status_expire.expires_at

    status.update!(text: 'hello #exp10m')
    described_class.new.call(status, [], replace: true)

    expect(status.reload.tags.pluck(:name)).to include('exp10m')
    expect(status.status_expire.expires_at).to be_within(1.second).of(expires_at)
  end
end
