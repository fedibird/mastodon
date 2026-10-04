# frozen_string_literal: true

require 'rails_helper'

describe RefreshEmojiReactionCacheWorker do
  subject(:worker) { described_class.new }

  it 'deduplicates queued refresh jobs until perform starts' do
    options = described_class.get_sidekiq_options

    expect(options['queue']).to eq 'pull'
    expect(options['retry']).to eq 1
    expect(options['dead']).to be false
    expect(options['lock']).to eq :until_executing
  end

  it 'rebuilds a dirty cache and clears the flag' do
    status = Fabricate(:status)
    account = Fabricate(:account)
    EmojiReaction.create!(account: account, status: status, name: '👍')
    status.status_stat.update!(emoji_reactions_cache: '[]', emoji_reactions_count: 0, emoji_reactions_cache_dirty: true)

    worker.perform(status.id)

    stat = status.status_stat.reload
    expect(stat.emoji_reactions_count).to eq 1
    expect(stat.emoji_reactions_cache_dirty).to be false
  end

  it 'does nothing when the cache is clean' do
    status = Fabricate(:status)
    StatusStat.create!(status: status, emoji_reactions_cache: 'keep', emoji_reactions_count: 2, emoji_reactions_cache_dirty: false)
    expect_any_instance_of(Status).not_to receive(:generate_grouped_emoji_reactions)

    worker.perform(status.id)

    expect(status.status_stat.reload.emoji_reactions_cache).to eq 'keep'
  end

  it 'does not raise when the status has been deleted' do
    expect(worker.perform(-1)).to be true
  end
end
