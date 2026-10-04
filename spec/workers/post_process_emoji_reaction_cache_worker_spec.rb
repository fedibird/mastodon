# frozen_string_literal: true

require 'rails_helper'

describe PostProcessEmojiReactionCacheWorker do
  it 'marks statuses that use the custom emoji dirty and kicks the batch processor' do
    custom_emoji = Fabricate(:custom_emoji, shortcode: 'postmoji')
    status = Fabricate(:status)
    account = Fabricate(:account)
    allow(RefreshDirtyEmojiReactionCachesWorker).to receive(:perform_async)
    EmojiReaction.create!(account: account, status: status, name: custom_emoji.shortcode, custom_emoji: custom_emoji)
    status.status_stat.update!(emoji_reactions_cache_dirty: false)

    described_class.new.perform([custom_emoji.id])

    expect(status.status_stat.reload.emoji_reactions_cache_dirty).to be true
    expect(RefreshDirtyEmojiReactionCachesWorker).to have_received(:perform_async)
  end
end
