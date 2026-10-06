# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PostingContext::DiscoveryService do
  describe '#call' do
    it 'resolves a local group with built-in Fedibird semantics' do
      account = Fabricate(:account, username: 'group', actor_type: 'Group')

      result = described_class.new.call(account)

      expect(result).to eq(
        schema_version: 1,
        account_id: account.id.to_s,
        status: 'resolved',
        context: {
          key: "builtin:fedibird-group:#{account.id}",
          source: {
            id: 'builtin:fedibird-group',
            revision: 1,
          },
          managed: {
            hashtags: [],
            mentions: [
              {
                account_id: account.id.to_s,
                acct: 'group',
                enforcement: 'required',
                rule_id: 'group-account-mention',
              },
            ],
          },
          requirements: {
            following_accounts: [
              {
                account_id: account.id.to_s,
                acct: 'group',
                enforcement: 'required',
                rule_id: 'group-follow',
              },
            ],
          },
          constraints: {
            allowed_visibilities: %w(public unlisted),
          },
        },
        discovery: {
          mechanism: 'built_in',
          adapter: 'fedibird_group',
          authority: 'server',
        },
      )
      expect(result).not_to have_key(:reason)
      expect(result[:context][:requirements][:following_accounts].first).not_to have_key(:following)
    end

    it 'returns unsupported for a remote group without contacting the network' do
      account = Fabricate(:account, username: 'group', domain: 'example.com', actor_type: 'Group')

      expect(Node).not_to receive(:resolve_domain)
      expect(UpdateNodeService).not_to receive(:new)
      expect(ResolveAccountService).not_to receive(:new)

      result = described_class.new.call(account)

      expect(result).to eq(
        schema_version: 1,
        account_id: account.id.to_s,
        status: 'unsupported',
        reason: 'no_supported_adapter',
        context: nil,
        discovery: {
          mechanism: nil,
          adapter: nil,
          authority: nil,
        },
      )
    end

    it 'returns not_applicable for a local person' do
      account = Fabricate(:account, username: 'alice', actor_type: 'Person')

      expect(described_class.new.call(account)).to include(
        schema_version: 1,
        account_id: account.id.to_s,
        status: 'not_applicable',
        reason: 'not_group',
        context: nil,
      )
    end

    it 'returns not_applicable for a remote person' do
      account = Fabricate(:account, username: 'alice', domain: 'example.com', actor_type: 'Person')

      expect(described_class.new.call(account)).to include(
        status: 'not_applicable',
        reason: 'not_group',
        context: nil,
      )
    end
  end
end
