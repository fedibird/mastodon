# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Fedibird::CapabilityCatalog do
  describe '.contextual REST extensions' do
    it 'derives supported notification types from the validator contract' do
      notifications = described_class.contextual.fetch(:notifications)

      expect(notifications[:scope]).to eq('viewer_and_client')
      expect(notifications[:collection_path]).to eq('/api/v1/notifications')
      expect(notifications[:supported_types]).to eq(Notification::TYPES.map(&:to_s))
      expect(notifications[:filters]).to eq(%w(types exclude_types account_id))
      expect(notifications.dig(:conditional_fields, :reblog)).to eq(%w(reblog_visibility))
      expect(notifications.dig(:conditional_fields, :emoji_reaction)).to eq(%w(emoji_reaction))
    end

    it 'describes authenticated preferences without reading them' do
      preferences = described_class.contextual.fetch(:preferences)

      expect(preferences[:scope]).to eq('authenticated_user')
      expect(preferences[:document_path]).to eq('/api/v1/fedibird/preferences')
      expect(preferences[:schema_path]).to eq('/api/v1/fedibird/preferences/schema')
      expect(preferences[:read_scope]).to eq('read:preferences')
      expect(preferences[:write_scope]).to eq('write:preferences')
    end

    it 'does not grant posting styles and identities to ordinary users' do
      contextual = described_class.contextual

      expect(contextual.dig(:posting_styles, :scope)).to eq('administrator')
      expect(contextual.dig(:posting_styles, :assignments_path)).to eq('/api/v1/fedibird/user_posting_context_assignments')
      expect(contextual.dig(:posting_styles, :max_per_user)).to eq(UserPostingContext::MAX_PER_USER)
      expect(contextual.dig(:posting_identities, :scope)).to eq('administrator')
      expect(contextual.dig(:posting_identities, :collection_path)).to eq('/api/v1/fedibird/posting_identities')
    end
  end
end
