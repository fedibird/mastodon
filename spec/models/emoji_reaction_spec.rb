require 'rails_helper'

RSpec.describe EmojiReaction, type: :model do
  let(:account) { Fabricate(:account) }
  let(:status) { Fabricate(:status) }

  def cached_names
    Oj.load(status.status_stat.reload.emoji_reactions_cache.presence || '[]', mode: :strict).map { |reaction| reaction['name'] }
  end

  it 'writes the cache and count when a reaction is created and leaves the row clean' do
    described_class.create!(account: account, status: status, name: '👍')

    stat = status.status_stat.reload
    expect(stat.emoji_reactions_count).to eq 1
    expect(cached_names).to eq ['👍']
    expect(stat.emoji_reactions_cache_dirty).to be false
  end

  it 'removes a reaction from the cache and count when it is destroyed' do
    reaction = described_class.create!(account: account, status: status, name: '👍')

    reaction.destroy!

    stat = status.status_stat.reload
    expect(stat.emoji_reactions_count).to eq 0
    expect(cached_names).to eq []
    expect(stat.emoji_reactions_cache_dirty).to be false
  end

  it 'keeps the committed reaction and the dirty flag when the cache refresh fails' do
    allow(RefreshEmojiReactionCacheWorker).to receive(:perform_async)
    allow_any_instance_of(Status).to receive(:generate_grouped_emoji_reactions).and_raise(StandardError, 'cache failed')

    expect do
      described_class.create!(account: account, status: status, name: '👍')
    end.to raise_error(StandardError, 'cache failed')

    expect(described_class.where(account: account, status: status, name: '👍')).to exist
    expect(status.status_stat.reload.emoji_reactions_cache_dirty).to be true
    expect(RefreshEmojiReactionCacheWorker).to have_received(:perform_async).with(status.id)
  end
end
