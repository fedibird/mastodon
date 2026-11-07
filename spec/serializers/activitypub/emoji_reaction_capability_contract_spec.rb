# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ActivityPub::EmojiReactionSerializer do
  let(:reaction) { EmojiReaction.new(name: '👍') }

  it 'only emits EmojiReact when explicitly selected for delivery' do
    expect(described_class.new(reaction, type: 'EmojiReact').type).to eq('EmojiReact')
    expect(described_class.new(reaction, type: 'Like').type).to eq('Like')
  end

  it 'does not turn an unknown delivery type into an EmojiReact claim' do
    expect(described_class.new(reaction, type: 'unknown').type).to eq('Like')
  end
end
