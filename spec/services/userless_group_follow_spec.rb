# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'User-less group follows' do
  before do
    allow(ActivityPub::DeliveryWorker).to receive(:perform_async)
    allow(LocalNotificationWorker).to receive(:perform_async)
  end

  let(:group) { Fabricate(:account, username: 'followgroup', actor_type: 'Group') }
  let(:local_bot) { Fabricate(:account, username: 'localbot', actor_type: 'Service') }
  let(:person) { Fabricate(:user, account: Fabricate(:account, username: 'personfollow')).account }

  def inbound_follow(sender, target, id: 'https://bots.example/follows/1')
    json = {
      '@context': 'https://www.w3.org/ns/activitystreams',
      id: id,
      type: 'Follow',
      actor: ActivityPub::TagManager.instance.uri_for(sender),
      object: ActivityPub::TagManager.instance.uri_for(target),
    }.with_indifferent_access
    ActivityPub::Activity::Follow.new(json, sender).perform
  end

  it 'accepts a bot follow of an unlocked group and still confirms a bot follow of a person' do
    FollowService.new.call(local_bot, group)
    expect(local_bot.following?(group)).to be true
    expect(local_bot.requested?(group)).to be false

    FollowService.new.call(local_bot, person)
    expect(local_bot.following?(person)).to be false
    expect(local_bot.requested?(person)).to be true

    remote_bot = Fabricate(
      :account,
      username: 'remotebot',
      domain: 'bots.example',
      actor_type: 'Service',
      protocol: :activitypub,
      uri: 'https://bots.example/users/remotebot',
      inbox_url: 'https://bots.example/inbox'
    )
    inbound_follow(remote_bot, group, id: 'https://bots.example/follows/group')
    expect(remote_bot.following?(group)).to be true
    expect(remote_bot.requested?(group)).to be false
  end

  it 'leaves a locked group as a follow request for people and bots' do
    group.update!(locked: true)
    member = Fabricate(:user).account

    FollowService.new.call(member, group)
    expect(member.requested?(group)).to be true
    expect(member.following?(group)).to be false

    inbound_follow(local_bot, group, id: 'https://example.test/follows/locked')
    expect(local_bot.requested?(group)).to be true
    expect(local_bot.following?(group)).to be false
  end

  it 'still rejects a blocked bot and does not follow the group from the group itself' do
    group.block!(local_bot)
    expect { FollowService.new.call(local_bot, group) }.to raise_error(Mastodon::NotPermittedError)
    expect(local_bot.following?(group)).to be false

    expect { FollowService.new.call(group, group) }.to raise_error(ActiveRecord::RecordNotFound)
  end
end
