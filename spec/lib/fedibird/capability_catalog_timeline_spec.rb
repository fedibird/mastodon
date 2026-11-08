# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Fedibird::CapabilityCatalog do
  describe '.contextual' do
    it 'publishes the existing TimelineSeek matrix without upgrading closed sources' do
      info = described_class.contextual.fetch(:timeline_seek)

      expect(info[:scope]).to eq('source_and_kind')
      expect(info[:version]).to eq(TimelineSeek::Capability::VERSION)
      expect(info.dig(:sources, 'home', 'date', :level)).to eq('approximate')
      expect(info.dig(:sources, 'public', 'status', :level)).to eq('supported')
      expect(info.dig(:sources, 'personal', 'account', :level)).to eq('unsupported')
      expect(info.dig(:sources, 'account', 'date', :level)).to eq('unsupported')
      expect(info.dig(:sources, 'mix', 'status', :level)).to eq('unsupported')
    end

    it 'keeps private capability queries at their own authenticated endpoints' do
      info = described_class.contextual

      expect(info.dig(:reading_bookmarks, :capability_path)).to eq('/api/v1/fedibird/reading_bookmarks/capabilities')
      expect(info.dig(:group_posting, :discovery_path)).to eq('/api/v1/fedibird/accounts/:account_id/posting_context')
      expect(info.dig(:posting_styles, :scope)).to eq('administrator')
      expect(info.dig(:emoji_reactions, :scope)).to eq('viewer_and_status')
    end
  end

  describe '.timeline_filters' do
    it 'advertises only filter parameters handled by each REST source' do
      info = described_class.timeline_filters

      expect(info[:only_media]).to include('home', 'public', 'hashtag', 'group', 'list', 'personal', 'account')
      expect(info[:without_media]).to contain_exactly('public', 'hashtag', 'group', 'personal')
      expect(info[:compact]).to include('home', 'public', 'hashtag', 'group', 'list', 'personal', 'account')
      expect(info[:without_media]).not_to include('list', 'home', 'account')
    end
  end
end
