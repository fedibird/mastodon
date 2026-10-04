require 'rails_helper'

RSpec.describe Status, type: :model do
  let(:alice) { Fabricate(:account, username: 'alice') }
  let(:bob)   { Fabricate(:account, username: 'bob') }
  let(:other) { Fabricate(:status, account: bob, text: 'Skulls for the skull god! The enemy\'s gates are sideways!') }

  subject { Fabricate(:status, account: alice) }

  describe '#local?' do
    it 'returns true when no remote URI is set' do
      expect(subject.local?).to be true
    end

    it 'returns false if a remote URI is set' do
      alice.update(domain: 'example.com')
      subject.save
      expect(subject.local?).to be false
    end

    it 'returns true if a URI is set and `local` is true' do
      subject.update(uri: 'example.com', local: true)
      expect(subject.local?).to be true
    end
  end

  describe '#reblog?' do
    it 'returns true when the status reblogs another status' do
      subject.reblog = other
      expect(subject.reblog?).to be true
    end

    it 'returns false if the status is self-contained' do
      expect(subject.reblog?).to be false
    end
  end

  describe '#decrement_counter_caches' do
    it 'does not change counters when an unsaved status is destroyed' do
      account = Fabricate(:account)
      parent = Fabricate(:status, account: account)
      unsaved = account.statuses.build(text: 'draft', thread: parent, visibility: :public)

      expect { unsaved.destroy }.not_to change { [account.reload.statuses_count, parent.reload.replies_count] }
    end
  end

  describe '#reply?' do
    it 'returns true if the status references another' do
      subject.thread = other
      expect(subject.reply?).to be true
    end

    it 'returns false if the status is self-contained' do
      expect(subject.reply?).to be false
    end
  end

  describe '#verb' do
    context 'if destroyed?' do
      it 'returns :delete' do
        subject.destroy!
        expect(subject.verb).to be :delete
      end
    end

    context 'unless destroyed?' do
      context 'if reblog?' do
        it 'returns :share' do
          subject.reblog = other
          expect(subject.verb).to be :share
        end
      end

      context 'unless reblog?' do
        it 'returns :post' do
          subject.reblog = nil
          expect(subject.verb).to be :post
        end
      end
    end
  end

  describe '#object_type' do
    it 'is note when the status is self-contained' do
      expect(subject.object_type).to be :note
    end

    it 'is comment when the status replies to another' do
      subject.thread = other
      expect(subject.object_type).to be :comment
    end
  end

  describe '#hidden?' do
    context 'if private_visibility?' do
      it 'returns true' do
        subject.visibility = :private
        expect(subject.hidden?).to be true
      end
    end

    context 'if direct_visibility?' do
      it 'returns true' do
        subject.visibility = :direct
        expect(subject.hidden?).to be true
      end
    end

    context 'if public_visibility?' do
      it 'returns false' do
        subject.visibility = :public
        expect(subject.hidden?).to be false
      end
    end

    context 'if unlisted_visibility?' do
      it 'returns false' do
        subject.visibility = :unlisted
        expect(subject.hidden?).to be false
      end
    end
  end

  describe '#content' do
    it 'returns the text of the status if it is not a reblog' do
      expect(subject.content).to eql subject.text
    end

    it 'returns the text of the reblogged status' do
      subject.reblog = other
      expect(subject.content).to eql other.text
    end
  end

  describe '#target' do
    it 'returns nil if the status is self-contained' do
      expect(subject.target).to be_nil
    end

    it 'returns nil if the status is a reply' do
      subject.thread = other
      expect(subject.target).to be_nil
    end

    it 'returns the reblogged status' do
      subject.reblog = other
      expect(subject.target).to eq other
    end
  end

  describe '#reblogs_count' do
    it 'is the number of reblogs' do
      Fabricate(:status, account: bob, reblog: subject)
      Fabricate(:status, account: alice, reblog: subject)

      expect(subject.reblogs_count).to eq 2
    end

    it 'is decremented when reblog is removed' do
      reblog = Fabricate(:status, account: bob, reblog: subject)
      expect(subject.reblogs_count).to eq 1
      reblog.destroy
      expect(subject.reblogs_count).to eq 0
    end

    it 'does not fail when original is deleted before reblog' do
      reblog = Fabricate(:status, account: bob, reblog: subject)
      expect(subject.reblogs_count).to eq 1
      expect { subject.destroy }.to_not raise_error
      expect(Status.find_by(id: reblog.id)).to be_nil
    end
  end

  describe '#replies_count' do
    it 'is the number of replies' do
      reply = Fabricate(:status, account: bob, thread: subject)
      expect(subject.replies_count).to eq 1
    end

    it 'is decremented when reply is removed' do
      reply = Fabricate(:status, account: bob, thread: subject)
      expect(subject.replies_count).to eq 1
      reply.destroy
      expect(subject.replies_count).to eq 0
    end
  end

  describe '#favourites_count' do
    it 'is the number of favorites' do
      Fabricate(:favourite, account: bob, status: subject)
      Fabricate(:favourite, account: alice, status: subject)

      expect(subject.favourites_count).to eq 2
    end

    it 'is decremented when favourite is removed' do
      favourite = Fabricate(:favourite, account: bob, status: subject)
      expect(subject.favourites_count).to eq 1
      favourite.destroy
      expect(subject.favourites_count).to eq 0
    end
  end

  describe '#proper' do
    it 'is itself for original statuses' do
      expect(subject.proper).to eq subject
    end

    it 'is the source status for reblogs' do
      subject.reblog = other
      expect(subject.proper).to eq other
    end
  end

  describe '.mutes_map' do
    let(:status)  { Fabricate(:status) }
    let(:account) { Fabricate(:account) }

    subject { Status.mutes_map([status.conversation.id], account) }

    it 'returns a hash' do
      expect(subject).to be_a Hash
    end

    it 'contains true value' do
      account.mute_conversation!(status.conversation)
      expect(subject[status.conversation.id]).to be true
    end
  end

  describe '.favourites_map' do
    let(:status)  { Fabricate(:status) }
    let(:account) { Fabricate(:account) }

    subject { Status.favourites_map([status], account) }

    it 'returns a hash' do
      expect(subject).to be_a Hash
    end

    it 'contains true value' do
      Fabricate(:favourite, status: status, account: account)
      expect(subject[status.id]).to be true
    end
  end

  describe '.reblogs_map' do
    let(:status)  { Fabricate(:status) }
    let(:account) { Fabricate(:account) }

    subject { Status.reblogs_map([status], account) }

    it 'returns a hash' do
      expect(subject).to be_a Hash
    end

    it 'contains true value' do
      Fabricate(:status, account: account, reblog: status)
      expect(subject[status.id]).to be true
    end
  end

  describe '.in_chosen_languages' do
    context 'for accounts with language filters' do
      let(:user) { Fabricate(:user, chosen_languages: ['en']) }

      it 'does not include statuses in not in chosen languages' do
        status = Fabricate(:status, language: 'de')
        expect(Status.in_chosen_languages(user.account)).not_to include status
      end

      it 'includes status with unknown language' do
        status = Fabricate(:status, language: nil)
        expect(Status.in_chosen_languages(user.account)).to include status
      end
    end
  end

  describe '.permitted_for' do
    subject { described_class.permitted_for(target_account, account).pluck(:visibility) }

    let(:target_account) { alice }
    let(:account) { bob }
    let!(:public_status) { Fabricate(:status, account: target_account, visibility: 'public') }
    let!(:unlisted_status) { Fabricate(:status, account: target_account, visibility: 'unlisted') }
    let!(:private_status) { Fabricate(:status, account: target_account, visibility: 'private') }

    let!(:direct_status) do
      Fabricate(:status, account: target_account, visibility: 'direct').tap do |status|
        Fabricate(:mention, status: status, account: account)
      end
    end

    let!(:other_direct_status) do
      Fabricate(:status, account: target_account, visibility: 'direct').tap do |status|
        Fabricate(:mention, status: status)
      end
    end

    context 'given nil' do
      let(:account) { nil }
      let(:direct_status) { nil }
      it { is_expected.to eq(%w(unlisted public)) }
    end

    context 'given blocked account' do
      before do
        target_account.block!(account)
      end

      it { is_expected.to be_empty }
    end

    context 'given same account' do
      let(:account) { target_account }
      it { is_expected.to eq(%w(direct direct private unlisted public)) }
    end

    context 'given followed account' do
      before do
        account.follow!(target_account)
      end

      it { is_expected.to eq(%w(direct private unlisted public)) }
    end

    context 'given unfollowed account' do
      it { is_expected.to eq(%w(direct unlisted public)) }
    end
  end

  describe 'before_validation' do
    it 'sets account being replied to correctly over intermediary nodes' do
      first_status = Fabricate(:status, account: bob)
      intermediary = Fabricate(:status, thread: first_status, account: alice)
      final        = Fabricate(:status, thread: intermediary, account: alice)

      expect(final.in_reply_to_account_id).to eq bob.id
    end

    it 'creates new conversation for stand-alone status' do
      expect(Status.create(account: alice, text: 'First').conversation_id).to_not be_nil
    end

    it 'keeps conversation of parent node' do
      parent = Fabricate(:status, text: 'First')
      expect(Status.create(account: alice, thread: parent, text: 'Response').conversation_id).to eq parent.conversation_id
    end

    it 'sets `local` to true for status by local account' do
      expect(Status.create(account: alice, text: 'foo').local).to be true
    end

    it 'sets `local` to false for status by remote account' do
      alice.update(domain: 'example.com')
      expect(Status.create(account: alice, text: 'foo').local).to be false
    end
  end

  describe 'validation' do
    it 'disallow empty uri for remote status' do
      alice.update(domain: 'example.com')
      status = Fabricate.build(:status, uri: '', account: alice)
      expect(status).to model_have_error_on_field(:uri)
    end
  end

  describe 'after_create' do
    it 'saves ActivityPub uri as uri for local status' do
      status = Status.create(account: alice, text: 'foo')
      status.reload
      expect(status.uri).to start_with('https://')
    end
  end

  describe '#grouped_emoji_reactions' do
    let(:status) { Fabricate(:status, account: alice) }
    let(:cached_reactions) { [{ 'name' => '👍', 'count' => 1, 'account_ids' => [alice.id.to_s] }] }
    let(:visible_cached_reactions) { cached_reactions.map { |reaction| reaction.merge('me' => false) } }

    def persist_emoji_reaction_stat(updated_at:, emoji_reactions_count:, emoji_reactions_cache:, dirty: false)
      stat = StatusStat.create!(status: status, emoji_reactions_count: emoji_reactions_count, emoji_reactions_cache: emoji_reactions_cache, emoji_reactions_cache_dirty: dirty, created_at: updated_at, updated_at: updated_at)
      stat.update_columns(created_at: updated_at, updated_at: updated_at)
      status.association(:status_stat).reset
      stat
    end

    before do
      allow(RefreshEmojiReactionCacheWorker).to receive(:perform_async)
      allow(RefreshDirtyEmojiReactionCachesWorker).to receive(:perform_async)
    end

    it 'returns a stored cache older than a day without enqueueing a refresh' do
      persist_emoji_reaction_stat(updated_at: 2.days.ago, emoji_reactions_count: 1, emoji_reactions_cache: cached_reactions.to_json)
      expect(status).not_to receive(:refresh_grouped_emoji_reactions!)

      expect(status.grouped_emoji_reactions).to eq visible_cached_reactions
      expect(RefreshEmojiReactionCacheWorker).not_to have_received(:perform_async)
      expect(RefreshDirtyEmojiReactionCachesWorker).not_to have_received(:perform_async)
      expect(status.status_stat.reload.emoji_reactions_cache).to eq cached_reactions.to_json
      expect(status.status_stat.updated_at).to be <= 1.day.ago
      expect(status.status_stat.emoji_reactions_cache_dirty).to be false
    end

    it 'returns a recently updated stale cache without treating updated_at as freshness' do
      persist_emoji_reaction_stat(updated_at: Time.current, emoji_reactions_count: 4, emoji_reactions_cache: cached_reactions.to_json)
      expect(status).not_to receive(:refresh_grouped_emoji_reactions!)

      expect(status.grouped_emoji_reactions).to eq visible_cached_reactions
      expect(RefreshEmojiReactionCacheWorker).not_to have_received(:perform_async)
      expect(status.status_stat.reload.emoji_reactions_count).to eq 4
    end

    it 'returns a dirty cache without repairing it on read' do
      persist_emoji_reaction_stat(updated_at: 2.days.ago, emoji_reactions_count: 1, emoji_reactions_cache: cached_reactions.to_json, dirty: true)
      expect(status).not_to receive(:refresh_grouped_emoji_reactions!)

      expect(status.grouped_emoji_reactions).to eq visible_cached_reactions
      expect(RefreshEmojiReactionCacheWorker).not_to have_received(:perform_async)
      expect(status.status_stat.reload.emoji_reactions_cache_dirty).to be true
      expect(status.status_stat.emoji_reactions_cache).to eq cached_reactions.to_json
    end

    it 'returns an empty list for a status with no persisted stat or reactions' do
      expect(StatusStat.where(status_id: status.id)).not_to exist
      expect(RefreshEmojiReactionCacheWorker).not_to receive(:perform_async)

      expect(status.grouped_emoji_reactions).to eq []
      expect(StatusStat.where(status_id: status.id)).not_to exist
    end

    it 'does not use status_stats.updated_at to decide that a blank cache needs rebuilding' do
      persist_emoji_reaction_stat(updated_at: 2.days.ago, emoji_reactions_count: 1, emoji_reactions_cache: '')
      expect(status).not_to receive(:refresh_grouped_emoji_reactions!)

      expect(status.grouped_emoji_reactions).to eq []
      expect(RefreshEmojiReactionCacheWorker).not_to have_received(:perform_async)
      expect(status.status_stat.reload.emoji_reactions_cache).to eq ''
    end

    it 'does not define an age-based staleness check' do
      expect(Status.private_instance_methods).not_to include(:emoji_reaction_cache_stale?)
    end
  end

  describe 'emoji reaction cache refresh' do
    let(:status) { Fabricate(:status, account: alice) }

    it 'rebuilds a dirty cache and clears the flag' do
      EmojiReaction.create!(account: alice, status: status, name: '👍')
      status.status_stat.update!(emoji_reactions_cache: '[]', emoji_reactions_count: 0, emoji_reactions_cache_dirty: true)

      status.refresh_grouped_emoji_reactions_if_dirty!

      stat = status.status_stat.reload
      expect(stat.emoji_reactions_count).to eq 1
      expect(stat.emoji_reactions_cache_dirty).to be false
      expect(Oj.load(stat.emoji_reactions_cache, mode: :strict).first['name']).to eq '👍'
    end

    it 'leaves a clean cache untouched' do
      StatusStat.create!(status: status, emoji_reactions_cache: '[]', emoji_reactions_count: 0, emoji_reactions_cache_dirty: false)
      expect(status).not_to receive(:generate_grouped_emoji_reactions)

      status.refresh_grouped_emoji_reactions_if_dirty!

      expect(status.status_stat.reload.emoji_reactions_cache).to eq '[]'
      expect(status.status_stat.emoji_reactions_cache_dirty).to be false
    end

    it 'rebuilds when forced even if the row is clean' do
      EmojiReaction.create!(account: alice, status: status, name: '👍')
      status.status_stat.update!(emoji_reactions_cache: '[]', emoji_reactions_count: 0, emoji_reactions_cache_dirty: false)

      status.refresh_grouped_emoji_reactions!(force: true)

      stat = status.status_stat.reload
      expect(stat.emoji_reactions_count).to eq 1
      expect(stat.emoji_reactions_cache_dirty).to be false
      expect(Oj.load(stat.emoji_reactions_cache, mode: :strict).first['count']).to eq 1
    end

    it 'keeps the dirty flag when rebuilding raises' do
      stat = StatusStat.create!(status: status, emoji_reactions_cache: '[]', emoji_reactions_count: 3, emoji_reactions_cache_dirty: true)
      allow(status).to receive(:generate_grouped_emoji_reactions).and_raise(StandardError, 'boom')

      expect { status.refresh_grouped_emoji_reactions! }.to raise_error(StandardError, 'boom')

      stat.reload
      expect(stat.emoji_reactions_cache_dirty).to be true
      expect(stat.emoji_reactions_cache).to eq '[]'
      expect(stat.emoji_reactions_count).to eq 3
    end

    it 'marks a row dirty without rewriting the stored cache' do
      stat = StatusStat.create!(status: status, emoji_reactions_cache: 'cached', emoji_reactions_count: 2, replies_count: 4, emoji_reactions_cache_dirty: false)

      status.mark_grouped_emoji_reactions_dirty!

      stat.reload
      expect(stat.emoji_reactions_cache_dirty).to be true
      expect(stat.emoji_reactions_cache).to eq 'cached'
      expect(stat.emoji_reactions_count).to eq 2
      expect(stat.replies_count).to eq 4
    end
  end
end

RSpec.describe Status, 'emoji reaction cache lock', type: :model do
  self.use_transactional_tests = false

  # Transactional fixtures pin every thread to the main connection via
  # lock_thread. A marker on that connection would run inside the refresh
  # transaction and could not block on the row lock.
  def with_dedicated_connection
    pool = ActiveRecord::Base.connection_pool
    pool.lock_thread = false
    conn = pool.checkout
    pool.instance_variable_get(:@thread_cached_conns)[Thread.current] = conn
    yield
  ensure
    if conn
      conn.rollback_db_transaction if conn.open_transactions.positive?
      pool.instance_variable_get(:@thread_cached_conns)&.delete(Thread.current)
      pool.checkin(conn)
    end
  end

  it 'does not let a refresh clear a dirty mark that arrived while the cache was generated' do
    account = Fabricate(:account)
    status = Fabricate(:status, account: account)
    StatusStat.create!(status: status, emoji_reactions_cache: '[]', emoji_reactions_count: 0, emoji_reactions_cache_dirty: true)

    started = Queue.new
    release = Queue.new
    errors = Queue.new
    refresher = nil
    marker = nil
    pool = ActiveRecord::Base.connection_pool
    pool.lock_thread = false
    ActiveRecord::Base.clear_active_connections!

    allow(status).to receive(:generate_grouped_emoji_reactions).and_wrap_original do |original|
      started << ActiveRecord::Base.connection.raw_connection.backend_pid
      release.pop
      original.call
    end

    refresher = Thread.new do
      with_dedicated_connection do
        status.refresh_grouped_emoji_reactions!
      end
    rescue StandardError => e
      errors << e
    end

    refresher_pid = Timeout.timeout(5) { started.pop }
    marker_pid = Queue.new

    marker = Thread.new do
      with_dedicated_connection do
        marker_pid << ActiveRecord::Base.connection.raw_connection.backend_pid
        Status.find(status.id).mark_grouped_emoji_reactions_dirty!
      end
    rescue StandardError => e
      errors << e
      marker_pid << nil
    end

    marked_pid = Timeout.timeout(5) { marker_pid.pop }
    blocked = false

    Timeout.timeout(5) do
      loop do
        raise errors.pop unless errors.empty?
        break unless marker.alive?

        waiting = ActiveRecord::Base.connection.select_value(
          "SELECT COUNT(*) FROM pg_stat_activity WHERE pid = #{marked_pid.to_i} AND wait_event_type = 'Lock'"
        )
        if waiting.to_i.positive?
          blocked = true
          break
        end

        sleep 0.01
      end
    end

    expect(blocked).to be(true), "marker pid=#{marked_pid.inspect} refresher pid=#{refresher_pid.inspect} marker_alive=#{marker.alive?}"

    release << true
    refresher.join
    marker.join

    expect(errors).to be_empty
    expect(StatusStat.find_by!(status_id: status.id).emoji_reactions_cache_dirty).to be true
  ensure
    release << true if defined?(release) && release
    refresher&.join(2)
    marker&.join(2)
    pool.lock_thread = true if defined?(pool) && pool
    ActiveRecord::Base.clear_active_connections!
    if defined?(status) && status&.id
      StatusStat.where(status_id: status.id).delete_all
      EmojiReaction.where(status_id: status.id).delete_all
      Status.unscoped.where(id: status.id).delete_all
    end
    Account.where(id: account.id).delete_all if defined?(account) && account&.id
  end
end
