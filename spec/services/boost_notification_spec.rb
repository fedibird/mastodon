# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Boost notification delivery', type: :service do
  let(:recipient) { Fabricate(:user).account }
  let(:booster) { Fabricate(:user).account }
  let(:author) { Fabricate(:user).account }
  let(:original) { Fabricate(:status, account: author) }
  let(:boost) { Fabricate(:status, account: booster, reblog: original) }

  def deliver(status = boost, **options)
    FanOutOnWriteService.new.call(status, **options)
  end

  def notifications
    Notification.where(account: recipient, type: :status)
  end

  before do
    allow(ActivityPub::DistributionWorker).to receive(:perform_async)
    allow(Web::PushNotificationWorker).to receive(:push_bulk)
  end

  [false, true].product([false, true]).each do |notify, notify_reblogs|
    it "keeps post notify=#{notify} and boost notify=#{notify_reblogs} independent" do
      recipient.follow!(booster, notify: notify, notify_reblogs: notify_reblogs)
      post = Fabricate(:status, account: booster)
      deliver(post)
      deliver
      expect(notifications.where(activity: post).count).to eq(notify ? 1 : 0)
      expect(notifications.where(activity: boost).count).to eq(notify_reblogs ? 1 : 0)
    end
  end

  it 'notifies without home delivery, boost display, or recent login' do
    recipient.user.update!(current_sign_in_at: 2.years.ago, last_sign_in_at: 2.years.ago)
    Fabricate(:web_push_subscription, user: recipient.user, data: { alerts: { status: true } })
    recipient.follow!(booster, reblogs: false, delivery: false, notify_reblogs: true)
    deliver
    expect(notifications.pluck(:activity_id)).to eq [boost.id]
    expect(Web::PushNotificationWorker).to have_received(:push_bulk).once
    expect(HomeFeed.new(recipient).get(20).map(&:id)).not_to include(boost.id, original.id)
  end

  it 'does not insert a hidden boost while delivering notifications' do
    recipient.follow!(booster, reblogs: false, notify_reblogs: true)
    deliver
    expect(notifications.count).to eq 1
    expect(HomeFeed.new(recipient).get(20).map(&:id)).not_to include(boost.id, original.id)
  end

  it 'sends one notification and one push enqueue for retries, home, and multiple lists' do
    recipient.follow!(booster, notify_reblogs: true)
    2.times { Fabricate(:list, account: recipient).accounts << booster }
    Fabricate(:web_push_subscription, user: recipient.user, data: { alerts: { status: true } })
    2.times { deliver }
    2.times { LocalNotificationWorker.new.perform(recipient.id, boost.id, 'Status', 'status') }
    expect(notifications.count).to eq 1
    expect(Web::PushNotificationWorker).to have_received(:push_bulk).once
  end

  it 'does not notify on edits' do
    recipient.follow!(booster, notify_reblogs: true)
    deliver(boost, update: true)
    expect(notifications).to be_empty
  end

  it 'keeps excluding replies to other accounts from ordinary post notifications' do
    recipient.follow!(booster, notify: true, notify_reblogs: true)
    reply = Fabricate(:status, account: booster, thread: original)
    deliver(reply)
    expect(notifications).to be_empty
  end

  it 'notifies again for a new wrapper after undoing a boost' do
    recipient.follow!(booster, notify_reblogs: true)
    deliver
    boost.destroy!
    second = Fabricate(:status, account: booster, reblog: original)
    expect { deliver(second) }.to change { notifications.count }.by(1)
    expect(notifications.where(activity: second)).to exist
  end

  it 'fails closed when the original is missing at execution time' do
    recipient.follow!(booster, notify_reblogs: true)
    allow(boost).to receive(:reblog).and_return(nil)
    expect { NotifyService.new.call(recipient, :status, boost) }.not_to change(Notification, :count)
  end

  it 'rechecks opt-in when an enqueued notification executes' do
    follow = recipient.follow!(booster, notify_reblogs: true)
    follow.update!(notify_reblogs: false)
    LocalNotificationWorker.new.perform(recipient.id, boost.id, 'Status', 'status')
    expect(notifications).to be_empty
  end

  it 'rechecks an unfollow when an enqueued notification executes' do
    recipient.follow!(booster, notify_reblogs: true).destroy!
    LocalNotificationWorker.new.perform(recipient.id, boost.id, 'Status', 'status')
    expect(notifications).to be_empty
  end

  %i(booster author).each do |who|
    %i(block mute blocked_by domain_block).each do |restriction|
      it "suppresses a boost for #{restriction} on #{who}" do
        recipient.follow!(booster, notify_reblogs: true)
        target = public_send(who)
        case restriction
        when :block then recipient.block!(target)
        when :mute then recipient.mute!(target, notifications: false)
        when :blocked_by then target.block!(recipient)
        when :domain_block
          target.update!(domain: "#{who}.example.org")
          recipient.block_domain!(target.domain)
        end
        deliver
        expect(notifications).to be_empty
      end
    end
  end

  it 'honors notification mutes on the booster' do
    recipient.follow!(booster, notify_reblogs: true)
    recipient.mute!(booster, notifications: true)
    deliver
    expect(notifications).to be_empty
  end

  it 'honors conversation mutes on the original' do
    recipient.follow!(booster, notify_reblogs: true)
    recipient.mute_conversation!(original.conversation)
    deliver
    expect(notifications).to be_empty
  end

  %i(public unlisted private limited direct personal).each do |visibility|
    %i(original boost).each do |which|
      it "checks #{visibility} visibility on the #{which}" do
        recipient.follow!(booster, notify_reblogs: true)
        public_send(which).update_columns(visibility: Status.visibilities.fetch(visibility.to_s))
        deliver
        visible = %i(public unlisted).include?(visibility) || (which == :boost && visibility == :private)
        expect(notifications.count).to eq(visible ? 1 : 0)
      end
    end
  end

  it 'allows a private original for its followers' do
    recipient.follow!(booster, notify_reblogs: true)
    recipient.follow!(author)
    original.update!(visibility: :private)
    deliver
    expect(notifications.count).to eq 1
  end

  it 'allows limited wrappers and originals only with both mentions' do
    recipient.follow!(booster, notify_reblogs: true)
    original.update!(visibility: :limited)
    boost.update!(visibility: :limited)
    Fabricate(:mention, status: original, account: recipient)
    deliver
    expect(notifications).to be_empty
    Fabricate(:mention, status: boost, account: recipient)
    deliver
    expect(notifications.count).to eq 1
  end

  %i(local remote).each do |source|
    [ ['ja', ['en'], 0], ['en', ['en'], 1], [nil, ['en'], 1], ['ja', [], 1] ].each do |language, languages, expected|
      it "filters #{source} boosts with original language=#{language.inspect}, follow languages=#{languages.inspect}" do
        original.update!(language: language)
        if source == :local
          recipient.follow!(booster, notify_reblogs: true, languages: languages)
          wrapper = ReblogService.new.call(booster, original, visibility: :public)
        else
          remote = Fabricate(:account, domain: 'example.com', uri: 'https://example.com/actor', followers_url: 'https://example.com/followers')
          recipient.follow!(remote, notify_reblogs: true, languages: languages)
          wrapper = announce(remote)
        end
        expect(wrapper.language).to be_nil
        expect(notifications.where(activity: wrapper).count).to eq expected
      end
    end
  end

  it 'uses the original language even when the wrapper has a different language' do
    recipient.follow!(booster, notify_reblogs: true, languages: ['en'])
    original.update!(language: 'en')
    boost.update!(language: 'ja')
    deliver
    expect(notifications.where(activity: boost).count).to eq 1
  end

  it 'keeps the existing home filter behavior for a language-less wrapper' do
    recipient.follow!(booster, notify_reblogs: true, languages: ['en'])
    original.update!(language: 'ja')
    boost.update!(language: nil)
    expect(FeedManager.instance.filter?(:home, boost, recipient)).to be false
    expect(FeedManager.instance.filter?(:status_notifications, boost, recipient)).to be true
  end

  it 'allows a delayed retry to notify again after the user clears the notification' do
    recipient.follow!(booster, notify_reblogs: true)
    Fabricate(:web_push_subscription, user: recipient.user, data: { alerts: { status: true } })
    deliver
    notifications.destroy_all
    expect { LocalNotificationWorker.new.perform(recipient.id, boost.id, 'Status', 'status') }.to change { notifications.count }.by(1)
    expect(Web::PushNotificationWorker).to have_received(:push_bulk).twice
  end

  it 'keeps the wrapper and booster in the notification REST contract' do
    recipient.follow!(booster, notify_reblogs: true)
    deliver
    json = JSON.parse(InlineRenderer.render(notifications.first!, recipient, :notification).to_json)
    expect(json['type']).to eq 'status'
    expect(json.dig('account', 'id')).to eq booster.id.to_s
    expect(json.dig('status', 'id')).to eq boost.id.to_s
    expect(json.dig('status', 'reblog', 'id')).to eq original.id.to_s
  end

  it 'preserves the separate reblog notification to the original author' do
    author.follow!(booster, notify_reblogs: true)
    wrapper = ReblogService.new.call(booster, original, visibility: :public)
    expect(Notification.where(account: author, activity: wrapper).pluck(:type)).to contain_exactly('reblog', 'status')
  end

  it 'delivers a remote Announce using its remote wrapper' do
    remote = Fabricate(:account, domain: 'example.com', uri: 'https://example.com/actor', followers_url: 'https://example.com/followers')
    recipient.follow!(remote, notify_reblogs: true)
    announce(remote)
    notification = notifications.first!
    expect(notification.from_account).to eq remote
    expect(notification.activity.account).to eq remote
    expect(notification.activity.reblog).to eq original
  end

  def announce(remote)
    json = {
      '@context': 'https://www.w3.org/ns/activitystreams',
      id: 'https://example.com/announce/1', type: 'Announce', actor: remote.uri,
      object: ActivityPub::TagManager.instance.uri_for(original),
      to: ['https://www.w3.org/ns/activitystreams#Public'],
    }.with_indifferent_access
    ActivityPub::Activity::Announce.new(json, remote, delivery: true).perform
  end
end
