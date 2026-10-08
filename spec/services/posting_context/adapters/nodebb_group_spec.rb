# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PostingContext::Adapters::NodebbGroup do # rubocop:disable Metrics/BlockLength
  describe '.applicable?' do
    it 'accepts a saved remote ActivityPub NodeBB group' do
      account = remote_group(domain: 'nodebb.example', software_name: 'nodebb')

      expect(described_class.applicable?(account)).to be true
    end

    it 'matches the NodeBB software name without regard to case' do
      account = remote_group(domain: 'mixed.example', software_name: 'NodeBB')

      expect(described_class.applicable?(account)).to be true
    end

    it 'rejects a NodeBB person' do
      domain = 'people.example'
      Node.create!(domain: domain, info: { 'software_name' => 'nodebb' })
      account = Fabricate(
        :account,
        username: 'alice',
        domain: domain,
        actor_type: 'Person',
        protocol: :activitypub,
        uri: "https://#{domain}/users/alice",
        inbox_url: "https://#{domain}/users/alice/inbox"
      )

      expect(described_class.applicable?(account)).to be false
    end

    it 'rejects a local group' do
      Node.create!(domain: 'nodebb.example', info: { 'software_name' => 'nodebb' })
      account = Fabricate(:account, username: 'category', actor_type: 'Group')

      expect(described_class.applicable?(account)).to be false
    end

    it 'rejects a Mitra group' do
      account = remote_group(domain: 'mitra.example', software_name: 'mitra')

      expect(described_class.applicable?(account)).to be false
    end

    it 'rejects unknown NodeInfo, forks, and an upstream-only name' do
      expect(described_class.applicable?(remote_group(domain: 'missing.example', software_name: :absent))).to be false
      expect(described_class.applicable?(remote_group(domain: 'blank.example', software_name: ''))).to be false
      expect(described_class.applicable?(remote_group(domain: 'fork.example', software_name: 'nodebb-fork'))).to be false
      expect(described_class.applicable?(remote_group(domain: 'upstream.example', software_name: 'mastodon', upstream_name: 'nodebb'))).to be false
    end

    it 'rejects a NodeBB group without a saved id, actor URI, or inbox' do
      saved = remote_group(domain: 'nodebb.example', software_name: 'nodebb')
      unsaved = Account.new(
        username: 'category',
        domain: 'nodebb.example',
        actor_type: 'Group',
        protocol: :activitypub,
        uri: 'https://nodebb.example/category/1',
        inbox_url: 'https://nodebb.example/category/1/inbox'
      )
      missing_target = remote_group(domain: 'blank-target.example', software_name: 'nodebb', uri: '', inbox_url: '')

      expect(described_class.applicable?(unsaved)).to be false
      expect(saved.id).to be_present
      expect(described_class.applicable?(missing_target)).to be false
    end
  end

  describe '.context' do
    it 'requires a mention and a public audience for the same saved account' do
      account = remote_group(domain: 'nodebb.example', software_name: 'nodebb', username: 'category')
      context = described_class.context(account)

      expect(described_class.mechanism).to eq 'nodeinfo_software'
      expect(described_class.adapter_name).to eq 'nodebb_group'
      expect(described_class.authority).to eq 'compatibility'
      expect(context[:key]).to eq "protocol:fep-1b12-nodebb:#{account.id}"
      expect(context.dig(:source, :id)).to eq 'compat:nodebb-fep-1b12'
      expect(context.dig(:constraints, :allowed_visibilities)).to eq %w(public)
      expect(context.dig(:managed, :mentions)).to eq [
        {
          account_id: account.id.to_s,
          acct: 'category@nodebb.example',
          enforcement: 'required',
          rule_id: 'nodebb-group-mention',
        },
      ]
      expect(context.dig(:protocol, :activitypub, :audience)).to include(
        account_id: account.id.to_s,
        acct: 'category@nodebb.example',
        enforcement: 'required',
        rule_id: 'fep-1b12-group-audience'
      )
    end
  end

  def remote_group(domain:, software_name:, username: 'category', upstream_name: nil, **account_attrs)
    unless software_name == :absent
      info = {}
      info['software_name'] = software_name unless software_name.nil?
      info['upstream_name'] = upstream_name if upstream_name
      Node.create!(domain: domain, info: info)
    end

    Fabricate(
      :account,
      {
        username: username,
        domain: domain,
        actor_type: 'Group',
        protocol: :activitypub,
        uri: "https://#{domain}/category/#{username}",
        inbox_url: "https://#{domain}/category/#{username}/inbox",
      }.merge(account_attrs)
    )
  end
end
