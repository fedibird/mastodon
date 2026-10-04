# frozen_string_literal: true

require 'rails_helper'

describe RefreshDirtyEmojiReactionCachesWorker do
  subject(:worker) { described_class.new }

  def dirty_stat(status, cache: '[]', count: 0)
    StatusStat.create!(status: status, emoji_reactions_cache: cache, emoji_reactions_count: count, emoji_reactions_cache_dirty: true)
  end

  it 'uses an until-executing lock so a follow-up enqueued during perform is kept' do
    expect(described_class.get_sidekiq_options['lock']).to eq :until_executing
  end

  it 'refreshes dirty statuses and leaves clean statuses alone' do
    dirty_status = Fabricate(:status)
    clean_status = Fabricate(:status)
    account = Fabricate(:account)
    EmojiReaction.create!(account: account, status: dirty_status, name: '👍')
    dirty_status.status_stat.update!(emoji_reactions_cache: '[]', emoji_reactions_count: 0, emoji_reactions_cache_dirty: true)
    StatusStat.create!(status: clean_status, emoji_reactions_cache: 'keep', emoji_reactions_count: 3, emoji_reactions_cache_dirty: false)

    worker.perform

    expect(dirty_status.status_stat.reload.emoji_reactions_count).to eq 1
    expect(dirty_status.status_stat.emoji_reactions_cache_dirty).to be false
    expect(clean_status.status_stat.reload.emoji_reactions_cache).to eq 'keep'
    expect(clean_status.status_stat.emoji_reactions_count).to eq 3
    expect(clean_status.status_stat.emoji_reactions_cache_dirty).to be false
  end

  it 'stops at the batch size and schedules the next batch while dirty rows remain' do
    stub_const("#{described_class}::BATCH_SIZE", 1)
    allow(described_class).to receive(:perform_async)
    first, second = [Fabricate(:status), Fabricate(:status)].sort_by(&:id)
    dirty_stat(first, cache: 'old')
    dirty_stat(second, cache: 'old')

    worker.perform

    expect(first.status_stat.reload.emoji_reactions_cache_dirty).to be false
    expect(second.status_stat.reload.emoji_reactions_cache_dirty).to be true
    expect(described_class).to have_received(:perform_async).with(first.id)
  end

  it 'schedules a follow-up when another status is invalidated during the batch' do
    target = Fabricate(:status)
    other = Fabricate(:status)
    dirty_stat(target)
    StatusStat.create!(status: other, emoji_reactions_cache: 'keep', emoji_reactions_count: 0, emoji_reactions_cache_dirty: false)
    allow(described_class).to receive(:perform_async)
    allow_any_instance_of(Status).to receive(:refresh_grouped_emoji_reactions_if_dirty!).and_wrap_original do |method, *args|
      EmojiReactionCacheInvalidator.mark_status!(other.id)
      method.call(*args)
    end

    worker.perform

    expect(other.status_stat.reload.emoji_reactions_cache_dirty).to be true
    expect(described_class).to have_received(:perform_async).at_least(:once)
  end
end
