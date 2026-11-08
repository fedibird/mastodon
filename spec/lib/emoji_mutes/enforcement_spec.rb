# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Emoji mute enforcement', type: :request do
  let(:author_user) { Fabricate(:user) }
  let(:author) { author_user.account }
  let(:viewer_user) { Fabricate(:user) }
  let(:viewer) { viewer_user.account }
  let(:reactor) { Fabricate(:account) }
  let(:booster_user) { Fabricate(:user) }
  let(:booster) { booster_user.account }
  let(:status) { Fabricate(:status, account: author, visibility: :public) }

  def with_flags(canonical:, idempotent:)
    ClimateControl.modify(
      'EMOJI_REACTION_CANONICAL_WRITES' => canonical ? 'true' : nil,
      'EMOJI_REACTION_IDEMPOTENT_RETRY' => idempotent ? 'true' : nil
    ) { yield }
  end

  def mute_unicode(account, native, **effects)
    user = account.user
    token = Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'write:mutes')
    post '/api/v1/fedibird/emoji_mutes',
         params: { emoji: { kind: 'unicode', native: native }, effects: effects.presence }.compact.to_json,
         headers: { 'Authorization' => "Bearer #{token.token}", 'Content-Type' => 'application/json' }
    expect(response).to have_http_status(:created)
  end

  before do
    allow(ActivityPub::DeliveryWorker).to receive(:perform_async)
    allow(ActivityPub::DeliveryWorker).to receive(:push_bulk)
    allow(ActivityPub::RawDistributionWorker).to receive(:perform_async)
    allow(ActivityPub::CustomEmojiDistributionWorker).to receive(:perform_async)
    allow_any_instance_of(EmojiMutes::ChangeNotifier).to receive(:publish)
  end

  describe 'new reactions' do
    it 'refuses REST and both ActivityPub types without saving a row or side effects' do
      mute_unicode(author, '👍')
      text = status.text

      expect do
        EmojiReactionService.new.call(reactor, status, '👍')
      end.to raise_error(Mastodon::NotPermittedError)
      expect(EmojiReaction.where(status: status)).to be_none
      expect(Notification.where(account: author)).to be_none
      expect(ActivityPub::CustomEmojiDistributionWorker).not_to have_received(:perform_async)
      expect(status.reload.text).to eq text

      %w(Like EmojiReact).each do |type|
        json = {
          id: "https://example.com/activities/#{type}",
          type: type,
          actor: ActivityPub::TagManager.instance.uri_for(reactor),
          object: ActivityPub::TagManager.instance.uri_for(status),
          content: '👍',
          signature: { type: 'RsaSignature2017' },
        }.with_indifferent_access
        expect do
          ActivityPub::Activity.factory(json, reactor).perform
        end.not_to change(EmojiReaction, :count)
      end
      expect(ActivityPub::RawDistributionWorker).not_to have_received(:perform_async)
      expect(ModerationInteractionEvent.where(status_id: status.id)).to be_none
    end

    it 'uses the original author, not the booster, for both canonical flag values' do
      mute_unicode(booster, '👍', reject_reactions_to_own_posts: true, hide_reactions: false)
      boost = Fabricate(:status, account: booster, reblog: status, visibility: :public)

      [false, true].each do |canonical|
        EmojiReaction.delete_all
        with_flags(canonical: canonical, idempotent: false) do
          expect { EmojiReactionService.new.call(reactor, boost, '👍') }.not_to raise_error
        end
        expect(EmojiReaction.find_by(account: reactor).status_id).to eq status.id
      end

      EmojiReaction.delete_all
      mute_unicode(author, '👍')
      [false, true].each do |canonical|
        with_flags(canonical: canonical, idempotent: true) do
          expect { EmojiReactionService.new.call(reactor, boost, '👍') }.to raise_error(Mastodon::NotPermittedError)
        end
      end
      expect(EmojiReaction.where(status: status)).to be_none
    end

    it 'does not repeat notification or delivery for an existing row after a mute' do
      with_flags(canonical: false, idempotent: false) do
        EmojiReactionService.new.call(reactor, status, '👍')
        mute_unicode(author, '👍')
        expect do
          EmojiReactionService.new.call(reactor, status, '👍')
        end.not_to change(Notification, :count)
      end
      expect(ActivityPub::CustomEmojiDistributionWorker).to have_received(:perform_async).once

      reaction = EmojiReaction.find_by!(account: reactor, status: status)
      json = {
        id: 'https://example.com/undo-react',
        type: 'Undo',
        actor: ActivityPub::TagManager.instance.uri_for(reactor),
        object: {
          id: 'https://example.com/react-1',
          type: 'EmojiReact',
          content: '👍',
          actor: ActivityPub::TagManager.instance.uri_for(reactor),
          object: ActivityPub::TagManager.instance.uri_for(status),
        },
      }.with_indifferent_access
      ActivityPub::Activity::Undo.new(json, reactor).perform
      expect(EmojiReaction.where(id: reaction.id)).to be_none
    end

    it 'keeps a remote rule after the cache row is deleted and does not copy it' do
      emoji = Fabricate(:custom_emoji, shortcode: 'remotecat', domain: 'remote.example')
      token = Fabricate(:accessible_access_token, resource_owner_id: author_user.id, scopes: 'write:mutes')
      post '/api/v1/fedibird/emoji_mutes',
           params: { emoji: { kind: 'custom', scope: 'remote', domain: 'remote.example', shortcode: 'remotecat' } }.to_json,
           headers: { 'Authorization' => "Bearer #{token.token}", 'Content-Type' => 'application/json' }
      expect(response).to have_http_status(:created)
      emoji.destroy!
      expect(ResolveURLService).not_to receive(:new)

      expect do
        EmojiReactionService.new.call(reactor, status, 'remotecat@remote.example')
      end.to raise_error(Mastodon::NotPermittedError)
      expect(CustomEmoji.where(shortcode: 'remotecat')).to be_none
      expect(EmojiReaction.count).to eq 0
    end
  end

  describe 'viewer projection' do
    let(:local_emoji) { Fabricate(:custom_emoji, shortcode: 'blobcat') }
    let(:remote_emoji) { Fabricate(:custom_emoji, shortcode: 'blobcat', domain: 'remote.example') }
    let(:other_emoji) { Fabricate(:custom_emoji, shortcode: 'blobcat', domain: 'other.example') }

    def react(account, emoji)
      EmojiReaction.create!(account: account, status: status, name: emoji.shortcode, custom_emoji: emoji)
    end

    it 'drops only the muted identity and does not write the viewer result into the shared cache' do
      react(Fabricate(:account, domain: 'a.example'), local_emoji)
      react(Fabricate(:account, domain: 'b.example'), remote_emoji)
      react(Fabricate(:account, domain: 'c.example'), other_emoji)
      status.refresh_grouped_emoji_reactions!
      original = status.status_stat.reload.emoji_reactions_cache
      expect(Oj.load(original).first).to include('v' => 2, 'name' => 'blobcat')

      token = Fabricate(:accessible_access_token, resource_owner_id: viewer_user.id, scopes: 'write:mutes')
      post '/api/v1/fedibird/emoji_mutes',
           params: { emoji: { kind: 'custom', scope: 'remote', domain: 'remote.example', shortcode: 'blobcat' } }.to_json,
           headers: { 'Authorization' => "Bearer #{token.token}", 'Content-Type' => 'application/json' }
      EmojiMutes::Current.reset

      visible = status.grouped_emoji_reactions(viewer)
      anonymous = status.grouped_emoji_reactions(nil)
      again = status.grouped_emoji_reactions(viewer)

      expect(visible.first['count']).to eq 2
      expect(visible.first['parts'].map { |part| part['domain'] }).to contain_exactly(nil, 'other.example')
      expect(anonymous.first['count']).to eq 3
      expect(again.first['count']).to eq 2
      expect(status.status_stat.reload.emoji_reactions_cache).to eq original
      expect(status.reload.text).to eq status.text
    end

    it 'does not mute a legacy group from its representative domain' do
      react(Fabricate(:account, domain: 'a.example'), local_emoji)
      react(Fabricate(:account, domain: 'b.example'), remote_emoji)
      payload = [{
        'name' => 'blobcat',
        'count' => 2,
        'domain' => 'remote.example',
        'account_ids' => EmojiReaction.where(status: status).pluck(:account_id).map(&:to_s),
      }]
      status.status_stat.update!(emoji_reactions_cache: payload.to_json, emoji_reactions_cache_dirty: false)
      token = Fabricate(:accessible_access_token, resource_owner_id: viewer_user.id, scopes: 'write:mutes')
      post '/api/v1/fedibird/emoji_mutes',
           params: { emoji: { kind: 'custom', scope: 'remote', domain: 'remote.example', shortcode: 'blobcat' } }.to_json,
           headers: { 'Authorization' => "Bearer #{token.token}", 'Content-Type' => 'application/json' }
      EmojiMutes::Current.reset
      EmojiMutes::Breakdown.prepare([status], viewer.id)

      visible = status.grouped_emoji_reactions(viewer)
      expect(visible.first['count']).to eq 1
      expect(visible.first['parts'].map { |part| part['custom_emoji_id'] }).to eq [local_emoji.id.to_s]

      EmojiMutes::Current.reset
      EmojiMutes::Breakdown.prepare([status], viewer.id, status_limit: 0)
      skipped = status.grouped_emoji_reactions(viewer)
      expect(skipped.first['count']).to eq 2
      expect(skipped.first).not_to have_key('parts')
    end

    it 'loads mute rules once for several statuses' do
      mute_unicode(viewer, '👍', hide_reactions: true, reject_reactions_to_own_posts: false)
      statuses = Array.new(3) do
        item = Fabricate(:status, account: author)
        EmojiReaction.create!(account: reactor, status: item, name: '👍')
        item.refresh_grouped_emoji_reactions!
        item
      end
      EmojiMutes::Current.reset
      queries = []
      callback = lambda do |_name, _start, _finish, _id, payload|
        sql = payload[:sql]
        queries << sql if sql.include?('emoji_mutes') && sql.match?(/SELECT/i)
      end
      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
        statuses.each { |item| item.grouped_emoji_reactions(viewer) }
      end
      expect(queries.size).to eq 1
      expect(statuses.first.grouped_emoji_reactions(viewer)).to eq []
    end
  end

  describe 'notifications and delayed delivery' do
    let!(:reaction) { EmojiReaction.create!(account: reactor, status: status, name: '👍') }
    let!(:notification) { Notification.create!(account: author, type: :emoji_reaction, activity: reaction) }

    it 'hides the row from index, show, and unread count, then shows it again' do
      expect(author.notifications.browserable.count).to eq 1
      mute_unicode(author, '👍', reject_reactions_to_own_posts: false, hide_reactions: true)
      scope = EmojiMutes::RuleSet.for(author.id).filter_notifications(author.notifications.browserable)
      expect(scope.count).to eq 0
      expect do
        author.notifications.without_suspended.find(notification.id)
        raise ActiveRecord::RecordNotFound if EmojiMutes::RuleSet.for(author.id).hides_notification?(notification)
      end.to raise_error(ActiveRecord::RecordNotFound)

      EmojiMute.find_by!(account: author).destroy!
      EmojiMuteRevision.find_by!(account: author).bump!
      EmojiMutes::Current.reset
      expect(EmojiMutes::RuleSet.for(author.id).filter_notifications(author.notifications).count).to eq 1
      expect(EmojiReaction.where(id: reaction.id)).to exist
    end

    it 'skips push and mail that were queued before the mute' do
      mute_unicode(author, '👍', hide_reactions: true, reject_reactions_to_own_posts: false)
      endpoint = 'https://updates.push.services.mozilla.com/push/v1/emoji-mute'
      subscription = Fabricate(:web_push_subscription, user: author_user, endpoint: endpoint, data: { alerts: { emoji_reaction: true } })
      stub_request(:post, endpoint)
      Web::PushNotificationWorker.new.perform(subscription.id, notification.id)
      expect(a_request(:post, endpoint)).not_to have_been_made

      mail = NotificationMailer.emoji_reaction(author, notification)
      expect(mail.message).to be_a(ActionMailer::Base::NullMail)
    end
  end

  it 'does not treat variation selectors as the same unicode reaction' do
    rules = EmojiMutes::RuleSet.new([
      EmojiMute.new(kind: 'unicode', native: '‼', hide_reactions: true, reject_reactions_to_own_posts: true, replace_in_text: false, hide_in_picker: false, replacement: '［絵文字］', revision: 1),
    ])
    expect(rules.hides_part?('native' => '‼', 'account_ids' => ['1'])).to be true
    expect(rules.hides_part?('native' => '‼️', 'account_ids' => ['1'])).to be false
    expect(EmojiMutes::UnicodeMatch.same?('‼', '‼️')).to be false
  end
end
