# frozen_string_literal: true

require 'rails_helper'

RSpec.describe EmojiReactionCapability::WriteConfig do
  def with_env(values, &block)
    ClimateControl.modify(values, &block)
  end

  describe '.canonical_writes?' do
    it 'is off unless the variable is the exact string true' do
      with_env(EMOJI_REACTION_CANONICAL_WRITES: nil) { expect(described_class.canonical_writes?).to be false }
      %w(1 TRUE on yes false).each do |value|
        with_env(EMOJI_REACTION_CANONICAL_WRITES: value) { expect(described_class.canonical_writes?).to be false }
      end
      with_env(EMOJI_REACTION_CANONICAL_WRITES: 'true') { expect(described_class.canonical_writes?).to be true }
    end
  end

  describe '.idempotent_retry?' do
    it 'is off unless the variable is the exact string true' do
      with_env(EMOJI_REACTION_IDEMPOTENT_RETRY: nil) { expect(described_class.idempotent_retry?).to be false }
      with_env(EMOJI_REACTION_IDEMPOTENT_RETRY: '1') { expect(described_class.idempotent_retry?).to be false }
      with_env(EMOJI_REACTION_IDEMPOTENT_RETRY: 'true') { expect(described_class.idempotent_retry?).to be true }
    end

    it 'does not follow the other flag' do
      with_env(EMOJI_REACTION_CANONICAL_WRITES: 'true', EMOJI_REACTION_IDEMPOTENT_RETRY: nil) do
        expect(described_class.canonical_writes?).to be true
        expect(described_class.idempotent_retry?).to be false
      end
    end
  end
end
