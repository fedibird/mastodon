# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Threadiverse group posting adapters' do # rubocop:disable Metrics/BlockLength
  {
    PostingContext::Adapters::LemmyGroup => {
      software: 'lemmy',
      key_prefix: 'protocol:fep-1b12-lemmy:',
      source_id: 'compat:lemmy-group-note',
      rule_id: 'lemmy-group-mention',
      placement: 'after_title',
    },
    PostingContext::Adapters::PiefedGroup => {
      software: 'piefed',
      key_prefix: 'protocol:fep-1b12-piefed:',
      source_id: 'compat:piefed-group-note',
      rule_id: 'piefed-group-mention',
      placement: 'append',
    },
  }.each do |adapter, definition|
    describe adapter do # rubocop:disable Metrics/BlockLength
      it 'accepts a saved remote ActivityPub community and rejects the other cases' do
        software = definition[:software]
        account = remote_group(domain: "#{software}.example", software_name: software, username: 'technology')

        expect(adapter.applicable?(account)).to be true
        expect(adapter.applicable?(remote_group(domain: "mixed-#{software}.example", software_name: software.capitalize == 'Piefed' ? 'PieFed' : 'Lemmy'))).to be true
        expect(adapter.applicable?(remote_group(domain: "#{software}-person.example", software_name: software, username: 'alice', actor_type: 'Person'))).to be false
        expect(adapter.applicable?(Fabricate(:account, username: "#{software}local", actor_type: 'Group'))).to be false
        expect(adapter.applicable?(remote_group(domain: "other-#{software}.example", software_name: software == 'lemmy' ? 'piefed' : 'lemmy'))).to be false
        expect(adapter.applicable?(remote_group(domain: "nodebb-#{software}.example", software_name: 'nodebb'))).to be false
        expect(adapter.applicable?(remote_group(domain: "missing-#{software}.example", software_name: :absent))).to be false
        expect(adapter.applicable?(remote_group(domain: "fork-#{software}.example", software_name: "#{software}-fork"))).to be false
        expect(adapter.applicable?(remote_group(domain: "upstream-#{software}.example", software_name: 'mastodon', upstream_name: software))).to be false
        expect(adapter.applicable?(remote_group(domain: "blank-#{software}.example", software_name: software, uri: '', inbox_url: ''))).to be false

        unsaved = Account.new(
          username: 'technology',
          domain: "#{software}.example",
          actor_type: 'Group',
          protocol: :activitypub,
          uri: "https://#{software}.example/c/technology",
          inbox_url: "https://#{software}.example/c/technology/inbox"
        )

        expect(adapter.applicable?(unsaved)).to be false
      end

      it 'builds a public compatibility context with the community mention placement' do
        software = definition[:software]
        account = remote_group(domain: "#{software}.example", software_name: software, username: 'technology')
        context = adapter.context(account)

        expect(adapter.mechanism).to eq 'nodeinfo_software'
        expect(adapter.adapter_name).to eq "#{software}_group"
        expect(adapter.authority).to eq 'compatibility'
        expect(context[:key]).to eq "#{definition[:key_prefix]}#{account.id}"
        expect(context.dig(:source, :id)).to eq definition[:source_id]
        expect(context.dig(:source, :revision)).to eq 1
        expect(context.dig(:managed, :hashtags)).to eq []
        expect(context.dig(:requirements, :following_accounts)).to eq []
        expect(context.dig(:constraints, :allowed_visibilities)).to eq %w(public)
        expect(context.dig(:managed, :mentions)).to eq [
          {
            account_id: account.id.to_s,
            acct: "technology@#{software}.example",
            enforcement: 'required',
            rule_id: definition[:rule_id],
            placement: definition[:placement],
          },
        ]
        expect(context.dig(:protocol, :activitypub, :audience)).to include(
          account_id: account.id.to_s,
          acct: "technology@#{software}.example",
          enforcement: 'required',
          rule_id: 'fep-1b12-group-audience'
        )
      end
    end
  end

  def remote_group(domain:, software_name:, username: 'technology', upstream_name: nil, **account_attrs)
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
        uri: "https://#{domain}/c/#{username}",
        inbox_url: "https://#{domain}/c/#{username}/inbox",
      }.merge(account_attrs)
    )
  end
end
