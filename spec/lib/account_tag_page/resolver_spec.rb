# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AccountTagPage::Resolver do
  def account_for(username:, domain:, url:)
    Fabricate(:account, username: username, domain: domain, uri: "https://#{domain}/users/#{username}", url: url)
  end

  def tag_named(name)
    Tag.find_or_create_by!(name: name)
  end

  describe 'remote Mastodon and Fedibird' do
    let(:account) { account_for(username: 'bob', domain: 'remote.example', url: 'https://remote.example/@bob') }

    it 'builds the confirmed public URL and encodes a non-ASCII tag once' do
      tag = tag_named('ハッシュ')
      url = described_class.call(account: account, tag: tag, software_name: 'Mastodon', software_version: '4.2.1')
      segment = url.split('/tagged/').last

      expect(url).to eq("https://remote.example/@bob/tagged/#{Addressable::URI.encode_component('ハッシュ', Addressable::URI::CharacterClasses::UNRESERVED)}")
      expect(Addressable::URI.unencode_component(segment)).to eq('ハッシュ')
      expect(segment).not_to include('%25')
      expect(url).not_to end_with('/')
      expect(Addressable::URI.parse(url).query).to be_nil
      expect(Addressable::URI.parse(url).fragment).to be_nil
    end

    it 'accepts Mastodon versions that include the tagged profile route' do
      tag = tag_named('rails')
      %w(2.8.0 2.8.0rc1 2.8.0-rc1 3.5.3 4.2.10+glitch 4.3.0-nightly.2024-05-01).each do |version|
        expect(described_class.call(account: account, tag: tag, software_name: 'mastodon', software_version: version)).to eq('https://remote.example/@bob/tagged/rails')
      end
    end

    it 'rejects Mastodon versions and other software that are not confirmed' do
      tag = tag_named('rails')
      cases = [
        ['mastodon', '2.7.4'],
        ['mastodon', '2.8'],
        ['mastodon', '2.8.0.1'],
        ['mastodon', 'dev'],
        ['fedibird', '0.1.0'],
        ['fedibird', '4.2.13'],
        ['pleroma', '2.5.0'],
        ['akkoma', '3.10.0'],
        ['misskey', '2024.11.0'],
        ['pixelfed', '0.12.0'],
        ['hometown', '1.0.8'],
        ['glitch', '4.2.10'],
      ]

      cases.each do |name, version|
        expect(described_class.call(account: account, tag: tag, software_name: name, software_version: version)).to be_nil
      end
    end

    it 'accepts only the published Fedibird NodeInfo version' do
      tag = tag_named('rails')

      expect(described_class.call(account: account, tag: tag, software_name: 'fedibird', software_version: '0.1')).to eq('https://remote.example/@bob/tagged/rails')
    end

    it 'accepts the Mastodon profile path and the actor path, and rejects other paths' do
      tag = tag_named('rails')
      at_user = account_for(username: 'erin', domain: 'remote.example', url: 'https://remote.example/@erin/')
      actor = account_for(username: 'frank', domain: 'remote.example', url: 'https://remote.example/users/frank')
      replies = account_for(username: 'gina', domain: 'remote.example', url: 'https://remote.example/@gina/with_replies')
      followers = account_for(username: 'hana', domain: 'remote.example', url: 'https://remote.example/users/hana/followers')
      other = account_for(username: 'ivan', domain: 'remote.example', url: 'https://remote.example/@someone')
      prefixed = account_for(username: 'june', domain: 'remote.example', url: 'https://remote.example/web/@june')

      expect(described_class.call(account: at_user, tag: tag, software_name: 'mastodon', software_version: '4.2.1')).to eq('https://remote.example/@erin/tagged/rails')
      expect(described_class.call(account: actor, tag: tag, software_name: 'mastodon', software_version: '4.2.1')).to eq('https://remote.example/@frank/tagged/rails')
      expect(described_class.call(account: replies, tag: tag, software_name: 'mastodon', software_version: '4.2.1')).to be_nil
      expect(described_class.call(account: followers, tag: tag, software_name: 'mastodon', software_version: '4.2.1')).to be_nil
      expect(described_class.call(account: other, tag: tag, software_name: 'mastodon', software_version: '4.2.1')).to be_nil
      expect(described_class.call(account: prefixed, tag: tag, software_name: 'mastodon', software_version: '4.2.1')).to be_nil
    end

    it 'omits the URL when the public profile host is not the Node host' do
      mismatched = account_for(username: 'cara', domain: 'remote.example', url: 'https://web.example/@cara')
      insecure = account_for(username: 'dino', domain: 'remote.example', url: 'http://remote.example/@dino')
      tag = tag_named('rails')

      expect(described_class.call(account: mismatched, tag: tag, software_name: 'mastodon', software_version: '4.2.1')).to be_nil
      expect(described_class.call(account: insecure, tag: tag, software_name: 'mastodon', software_version: '4.2.1')).to be_nil
    end

    it 'omits the URL for a username or tag outside the confirmed path' do
      dotted = account_for(username: 'bob.smith', domain: 'remote.example', url: 'https://remote.example/@bob.smith')

      expect(described_class.call(account: dotted, tag: tag_named('rails'), software_name: 'mastodon', software_version: '4.2.1')).to be_nil
      expect(described_class.call(account: account, tag: 'a/b', software_name: 'mastodon', software_version: '4.2.1')).to be_nil
      expect(described_class.call(account: account, tag: '100%', software_name: 'mastodon', software_version: '4.2.1')).to be_nil
    end
  end

  describe 'local accounts' do
    let(:account) { Fabricate(:account, username: 'alice') }

    it 'uses the existing public tagged page and does not consult NodeInfo' do
      tag = tag_named('rails')

      generated = described_class.call(account: account, tag: tag, software_name: nil, software_version: nil)
      uri = Addressable::URI.parse(generated)

      expect(uri.path).to eq('/@alice/tagged/rails')
      expect(uri.query).to be_nil
      expect(described_class.call(account: account, tag: tag, software_name: 'pleroma', software_version: '2.4.0')).to eq(generated)
    end
  end
end
