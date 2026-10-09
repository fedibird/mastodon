# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PostingIdentity::SubmissionAccount do
  let(:user) { Fabricate(:user, account: Fabricate(:account, username: 'ada')) }
  let(:other) { Fabricate(:user, account: Fabricate(:account, username: 'bea')) }

  it 'returns the authenticated account for that account’s own ready identity' do
    expect(described_class.resolve!(user, "local:#{user.account_id}")).to eq user.account
  end

  it 'does not grant another user’s account from a client identity id' do
    expect { described_class.resolve!(user, "local:#{other.account_id}") }.to raise_error(Mastodon::NotPermittedError)
    expect(PostingIdentity::Catalog.new(user).identity_for("local:#{other.account_id}")).to be_nil
  end

  it 'does not grant an external or unknown identity id' do
    expect { described_class.resolve!(user, 'mastodon:someone') }.to raise_error(Mastodon::NotPermittedError)
    expect { described_class.resolve!(user, nil) }.to raise_error(Mastodon::NotPermittedError)
  end

  it 'does not grant the local identity when posting is restricted' do
    user.settings.disable_post = true

    expect { described_class.resolve!(user, "local:#{user.account_id}") }.to raise_error(Mastodon::NotPermittedError)
  end

  it 'does not grant the local identity when the account is suspended' do
    user.account.update!(suspended_at: Time.now.utc)

    expect { described_class.resolve!(user, "local:#{user.account_id}") }.to raise_error(Mastodon::NotPermittedError)
  end
end
