# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PostingIdentity do # rubocop:disable Metrics/BlockLength
  let(:user) { Fabricate(:user, account: Fabricate(:account, username: 'sender', display_name: 'Sender')) }

  describe PostingIdentity::Local do
    it 'derives a ready local identity from the signed-in account' do
      identity = PostingIdentity::Local.build(user)

      expect(identity.id).to eq "local:#{user.account.id}"
      expect(identity.kind).to eq 'local'
      expect(identity.provider).to eq 'fedibird'
      expect(identity.account).to eq user.account
      expect(identity.authorization).to eq 'ready'
      expect(identity.capabilities).to eq(
        'post' => 'supported',
        'media' => 'supported',
        'reply' => 'supported',
        'group' => 'supported',
        'schedule' => 'supported'
      )
    end

    it 'does not mark a suspended account ready' do
      user.account.update!(suspended_at: Time.now.utc)

      identity = PostingIdentity::Local.build(user)

      expect(identity.authorization).to eq 'unavailable'
      expect(identity.capabilities.values).to all(eq 'unavailable')
    end

    it 'does not mark a disabled account ready' do
      user.disable!

      identity = PostingIdentity::Local.build(user)

      expect(identity.authorization).to eq 'unavailable'
      expect(identity.capabilities['post']).to eq 'unavailable'
    end

    it 'does not ignore a posting restriction' do
      user.settings.disable_post = true

      identity = PostingIdentity::Local.build(user)

      expect(user.functional?).to be true
      expect(identity.authorization).to eq 'unavailable'
      expect(identity.capabilities.values).to all(eq 'unavailable')
    end
  end

  describe PostingIdentity::Catalog do
    it 'lists only the signed-in account' do
      other = Fabricate(:account, username: 'other')
      catalog = PostingIdentity::Catalog.new(user)

      expect(catalog.default_identity_id).to eq "local:#{user.account.id}"
      expect(catalog.identities.map { |identity| identity.account.id }).to eq [user.account.id]
      expect(catalog.identities.map { |identity| identity.account.id }).not_to include(other.id)
    end
  end

  describe PostingIdentity::SendGuard do
    it 'returns the authenticated account and does not load a client account id' do
      sender_user = user
      other = Fabricate(:account)

      expect(Account).not_to receive(:find)
      expect(Account).not_to receive(:find_by)

      sender = PostingIdentity::SendGuard.call!(
        user: sender_user,
        posting_identity_id: "local:#{sender_user.account.id}"
      )

      expect(sender).to eq sender_user.account
      expect(sender).not_to eq other
    end

    it 'rejects another identity without granting that account' do
      other = Fabricate(:account)

      expect do
        PostingIdentity::SendGuard.call!(
          user: user,
          posting_identity_id: "local:#{other.id}"
        )
      end.to raise_error(Mastodon::NotPermittedError)
    end

    it 'rejects any client account id' do
      expect do
        PostingIdentity::SendGuard.call!(user: user, account_id: user.account.id)
      end.to raise_error(Mastodon::NotPermittedError)
    end

    it 'rejects the signed-in identity when posting is not allowed' do
      user.settings.disable_post = true

      expect do
        PostingIdentity::SendGuard.call!(
          user: user,
          posting_identity_id: "local:#{user.account.id}"
        )
      end.to raise_error(Mastodon::NotPermittedError)
    end
  end
end
