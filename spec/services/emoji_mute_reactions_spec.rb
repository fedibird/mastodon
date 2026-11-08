# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Emoji mute reaction policy' do
  let(:author_user) { Fabricate(:user) }
  let(:author) { author_user.account }
  let(:reactor) { Fabricate(:account) }
  let(:booster_user) { Fabricate(:user) }
  let(:booster) { booster_user.account }
  let(:sender) { Fabricate(:account, domain: 'remote.test', uri: 'https://remote.test/users/sender') }

  def with_flags(canonical:, idempotent:, &block)
    ClimateControl.modify(
      {
        'EMOJI_REACTION_CANONICAL_WRITES' => canonical ? 'true' : nil,
        'EMOJI_REACTION_IDEMPOTENT_RETRY' => idempotent ? 'true' : nil,
      },
      &block
    )
  end

  def mute_unicode(owner, native = '👍', **effects)
    EmojiMutes::Repository.new(owner).create({
      'emoji' => { 'kind' => 'unicode', 'native' => native },
      'effects' => {
        'replace_in_text' => true,
        'reject_reactions_to_own_posts' => true,
        'hide_reactions' => true,
        'hide_in_picker' => true,
      }.merge(effects.stringify_keys),
    })
  end

  def react(status, emoji = '👍')
    EmojiReactionService.new.call(reactor, status, emoji)
  end

  around { |example| Sidekiq::Testing.fake! { example.run } }

  before do
    ActivityPub::CustomEmojiDistributionWorker.jobs.clear
    ActivityPub::DeliveryWorker.jobs.clear
    allow(PotentialFriendshipTracker).to receive(:record)
  end

  it 'rejects a new REST reaction for the original author and not the boost author' do
    status = Fabricate(:status, account: author)
    wrapper = Fabricate(:status, account: booster, reblog: status, text: '')
    mute_unicode(author_user)
    mute_unicode(booster_user, '🎉')

    [true, false].each do |canonical|
        EmojiReaction.delete_all
        Notification.delete_all
        ModerationInteractionEvent.delete_all
        ActivityPub::CustomEmojiDistributionWorker.jobs.clear

        with_flags(canonical: canonical, idempotent: false) do
          expect { react(wrapper) }.to raise_error(Mastodon::NotPermittedError)
        end

        expect(EmojiReaction.count).to eq 0
        expect(Notification.count).to eq 0
        expect(ModerationInteractionEvent.count).to eq 0
        expect(ActivityPub::CustomEmojiDistributionWorker.jobs).to be_empty
        expect(PotentialFriendshipTracker).not_to have_received(:record)
    end

    EmojiMutes::Store.rule_sets = nil
    mute = EmojiMute.find_by!(user: author_user)
    EmojiMutes::Repository.new(author_user).update(mute, {
      'expected_revision' => '1',
      'effects' => { 'reject_reactions_to_own_posts' => false },
    })
    with_flags(canonical: false, idempotent: false) do
      expect(react(wrapper).status_id).to eq status.id
    end
  end

  it 'does not revive side effects when an existing reaction is repeated with idempotent retry off' do
    status = Fabricate(:status, account: author)
    with_flags(canonical: true, idempotent: false) do
      react(status)
    end
    expect(Notification.where(activity_type: 'EmojiReaction').count).to eq 1
    mute_unicode(author_user)
    EmojiMutes::Store.rule_sets = nil
    ActivityPub::CustomEmojiDistributionWorker.jobs.clear

    with_flags(canonical: false, idempotent: false) do
      expect { react(status) }.not_to change { Notification.where(activity_type: 'EmojiReaction').count }
    end
    expect(ActivityPub::CustomEmojiDistributionWorker.jobs).to be_empty
    expect(PotentialFriendshipTracker).to have_received(:record).once
    expect { UnEmojiReactionService.new.call(reactor, status, '👍') }.to change(EmojiReaction, :count).by(-1)
  end

  it 'ignores a new ActivityPub EmojiReact and Like reaction without copying an emoji' do
    status = Fabricate(:status, account: author)
    mute_unicode(author_user)
    reaction = {
      '@context': 'https://www.w3.org/ns/activitystreams',
      id: 'https://remote.test/activities/react-1',
      type: 'EmojiReact',
      actor: ActivityPub::TagManager.instance.uri_for(sender),
      object: ActivityPub::TagManager.instance.uri_for(status),
      content: '👍',
    }.with_indifferent_access

    expect(ResolveURLService).not_to receive(:new)
    expect { ActivityPub::Activity::Like.new(reaction, sender).perform }.not_to change { [EmojiReaction.count, Notification.count, ModerationInteractionEvent.count, CustomEmoji.count] }

    favourite = reaction.merge(id: 'https://remote.test/activities/like-1', type: 'Like', content: nil)
    expect { ActivityPub::Activity::Like.new(favourite, sender).perform }.to change { Favourite.where(account: sender, status: status).count }.by(1)
  end

  it 'ignores a remote custom reaction before copying it and still accepts Undo' do
    status = Fabricate(:status, account: author)
    EmojiMutes::Repository.new(author_user).create({
      'emoji' => { 'kind' => 'custom', 'scope' => 'remote', 'domain' => 'remote.test', 'shortcode' => 'blob' },
    })
    reaction = {
      id: 'https://remote.test/activities/react-blob',
      type: 'EmojiReact',
      actor: ActivityPub::TagManager.instance.uri_for(sender),
      object: ActivityPub::TagManager.instance.uri_for(status),
      content: ':blob:',
      tag: [{
        'type' => 'Emoji',
        'name' => ':blob:',
        'id' => 'https://remote.test/emoji/blob',
        'icon' => { 'url' => 'https://remote.test/blob.png' },
      }],
    }.with_indifferent_access

    expect { ActivityPub::Activity::Like.new(reaction, sender).perform }.not_to change { [EmojiReaction.count, CustomEmoji.count, Notification.count] }

    emoji = Fabricate(:custom_emoji, shortcode: 'blob', domain: 'remote.test')
    EmojiReaction.create!(account: sender, status: status, name: 'blob', custom_emoji: emoji, uri: reaction[:id])
    undo = {
      id: 'https://remote.test/activities/undo-blob',
      type: 'Undo',
      actor: ActivityPub::TagManager.instance.uri_for(sender),
      object: reaction,
    }.with_indifferent_access
    expect { ActivityPub::Activity::Undo.new(undo, sender).perform }.to change { EmojiReaction.where(account: sender, status: status).count }.by(-1)
  end

  it 'does not repair moderation when a muted reaction is delivered again' do
    status = Fabricate(:status, account: author)
    reaction = {
      id: 'https://remote.test/activities/react-again',
      type: 'EmojiReact',
      actor: ActivityPub::TagManager.instance.uri_for(sender),
      object: ActivityPub::TagManager.instance.uri_for(status),
      content: '👍',
    }.with_indifferent_access
    ActivityPub::Activity::Like.new(reaction, sender).perform
    expect(ModerationInteractionEvent.count).to eq 1
    mute_unicode(author_user)

    expect { ActivityPub::Activity::Like.new(reaction, sender).perform }.not_to change(ModerationInteractionEvent, :count)
    expect(EmojiReaction.where(status: status, account: sender).count).to eq 1
  end

  it 'matches a variation selector and not a different skin tone' do
    stored = '👍🏽'
    expect(EmojiMutes::UnicodeMatch.match?(stored, "👍🏽\uFE0F")).to be true
    expect(EmojiMutes::UnicodeMatch.match?(stored, '👍')).to be false
  end
end
