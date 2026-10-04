# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/mastodon/cache_cli')

RSpec.describe Mastodon::CacheCLI do
  def invoke(arguments, **options)
    cli = described_class.new
    # Thor#invoke dispatches a new instance, so the stub has to sit on the
    # same object that runs recount. Calling the real helper would
    # establish_connection and drop this example's transaction.
    cli.options = { concurrency: 1 }.merge(options)
    allow(cli).to receive(:parallelize_with_progress) do |scope, &block|
      scope.find_each do |status|
        begin
          block.call(status)
        rescue StandardError
          nil
        end
      end
      [scope.count, 0]
    end

    stdout = $stdout
    $stdout = StringIO.new
    cli.recount(arguments.first)
  ensure
    $stdout = stdout
  end

  it 'repairs a dirty cache that no longer has reaction rows' do
    status = Fabricate(:status)
    StatusStat.create!(status: status, emoji_reactions_cache: '[{"name":"👍","count":2,"account_ids":["1"]}]', emoji_reactions_count: 2, emoji_reactions_cache_dirty: true)
    clean = Fabricate(:status)
    StatusStat.create!(status: clean, emoji_reactions_cache: 'keep', emoji_reactions_count: 4, emoji_reactions_cache_dirty: false)

    invoke(['emoji-reactions'], dirty_only: true, concurrency: 1)

    stat = status.status_stat.reload
    expect(stat.emoji_reactions_count).to eq 0
    expect(Oj.load(stat.emoji_reactions_cache.presence || '[]', mode: :strict)).to eq []
    expect(stat.emoji_reactions_cache_dirty).to be false
    expect(clean.status_stat.reload.emoji_reactions_cache).to eq 'keep'
    expect(clean.status_stat.emoji_reactions_count).to eq 4
    expect(clean.status_stat.emoji_reactions_cache_dirty).to be false
  end

  it 'repairs a stale clean cache on a full emoji-reactions recount' do
    status = Fabricate(:status)
    account = Fabricate(:account)
    EmojiReaction.create!(account: account, status: status, name: '👍')
    status.status_stat.update!(emoji_reactions_cache: '[]', emoji_reactions_count: 0, emoji_reactions_cache_dirty: false)

    invoke(['emoji-reactions'], concurrency: 1)

    stat = status.status_stat.reload
    expect(stat.emoji_reactions_count).to eq 1
    expect(stat.emoji_reactions_cache_dirty).to be false
    expect(Oj.load(stat.emoji_reactions_cache, mode: :strict).first['name']).to eq '👍'
  end

  it 'clears dirty only for rows whose rebuild succeeds' do
    healthy = Fabricate(:status)
    failing = Fabricate(:status)
    StatusStat.create!(status: healthy, emoji_reactions_cache: '[]', emoji_reactions_count: 0, emoji_reactions_cache_dirty: true)
    StatusStat.create!(status: failing, emoji_reactions_cache: 'stale', emoji_reactions_count: 2, emoji_reactions_cache_dirty: true)
    allow_any_instance_of(Status).to receive(:generate_grouped_emoji_reactions).and_wrap_original do |method, *args|
      raise StandardError, 'boom' if method.receiver.id == failing.id

      method.call(*args)
    end

    invoke(['emoji-reactions'], dirty_only: true, concurrency: 1)

    expect(healthy.status_stat.reload.emoji_reactions_cache_dirty).to be false
    failing_stat = failing.status_stat.reload
    expect(failing_stat.emoji_reactions_cache_dirty).to be true
    expect(failing_stat.emoji_reactions_cache).to eq 'stale'
    expect(failing_stat.emoji_reactions_count).to eq 2
  end
end
