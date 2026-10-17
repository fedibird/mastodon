# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Web::NotificationSerializer do
  let(:user) { Fabricate(:user) }
  let(:booster) { Fabricate(:account, display_name: 'Booster', note: 'Booster profile') }
  let(:original) { Fabricate(:status, text: 'Original &amp; 😀', spoiler_text: '') }
  let(:boost) { Fabricate(:status, account: booster, reblog: original, text: '') }
  let(:notification) { Fabricate(:notification, account: user.account, from_account: booster, activity: boost, type: :status) }
  let(:subscription) { Fabricate(:web_push_subscription, user: user, data: { alerts: { status: true, reblog: false } }) }
  let(:serializer) { described_class.new(notification, scope: subscription, scope_name: :current_push_subscription) }

  it 'keeps the payload schema, status type, wrapper notification ID and original body' do
    json = serializer.as_json
    expect(json.keys).to match_array([:access_token, :preferred_locale, :notification_id, :notification_type, :icon, :title, :body])
    expect(json[:notification_id]).to eq notification.id
    expect(json[:notification_type]).to eq :status
    expect(json[:body]).to eq 'Original & 😀'
    expect(subscription.pushable?(notification)).to be true
    subscription.update!(data: { alerts: { status: false, reblog: true } })
    expect(subscription.pushable?(notification)).to be false
  end

  {
    en: ['Booster boosted a post', 'Booster just posted', 'Booster boosted your post'],
    ja: ['Boosterさんがブーストしました', 'Booster さんが投稿しました', 'Booster さんにブーストされました'],
  }.each do |locale, titles|
    context "in #{locale}" do
      around { |example| I18n.with_locale(locale) { example.run } }

      it 'uses the booster for a followed boost title' do
        expect(serializer.title).to eq titles[0]
      end

      it 'preserves the ordinary status title and CW priority' do
        notification.activity = Fabricate(:status, account: booster, text: 'Ordinary post', spoiler_text: 'Ordinary CW')
        expect(serializer.title).to eq titles[1]
        expect(serializer.body).to eq 'Ordinary CW'
      end

      it 'preserves the traditional reblog title and original body' do
        notification = Fabricate(:notification, account: user.account, from_account: booster, activity: boost, type: :reblog)
        serializer = described_class.new(notification)
        expect(serializer.title).to eq titles[2]
        expect(serializer.body).to eq 'Original &amp; 😀'
      end
    end
  end

  it 'prefers and sanitizes the original CW' do
    original.update!(spoiler_text: '<b>CW &amp; 😀</b>')
    expect(serializer.body).to eq 'CW & 😀'
  end

  it 'handles a CW-only original' do
    notification.target_status.reblog.assign_attributes(text: '', spoiler_text: 'CW only')
    expect(serializer.body).to eq 'CW only'
  end

  it 'strips malformed HTML and decodes entities in the original body' do
    original.update!(text: '<p>Hello <b>world &amp; 😀</p><script>alert(1)</script><img src=x onerror=bad()>')
    expect(serializer.body).to eq 'Hello world & 😀'
  end

  it 'truncates the decoded original text to 140 characters' do
    notification.target_status.reblog.assign_attributes(text: '😀&amp;' * 100)
    expect(serializer.body).to eq("#{('😀&' * 100).first(137)}...")
    expect(serializer.body.length).to eq 140
  end

  it 'uses an empty body for an empty original instead of the booster profile' do
    notification.target_status.reblog.assign_attributes(text: '', spoiler_text: '')
    expect(serializer.body).to eq ''
  end

  it 'handles a missing original without leaking the booster profile' do
    allow(notification.target_status).to receive(:reblog).and_return(nil)
    expect(serializer.body).to eq ''
    expect(serializer.title).to eq 'Booster boosted a post'
  end

  it 'handles a missing wrapper with the existing status fallback' do
    allow(notification).to receive(:target_status).and_return(nil)
    expect(serializer.title).to eq 'Booster just posted'
    expect(serializer.body).to eq 'Booster profile'
  end

  it 'falls back to the booster username' do
    booster.display_name = ''
    expect(serializer.title).to eq "#{booster.username} boosted a post"
  end

  it 'uses the subscription locale through the existing worker serializer path' do
    user.update!(locale: 'ja')
    worker = Web::PushNotificationWorker.new
    worker.instance_variable_set(:@notification, notification)
    worker.instance_variable_set(:@subscription, subscription)
    json = Oj.load(worker.send(:push_notification_json))
    expect(json['title']).to eq 'Boosterさんがブーストしました'
    expect(json['body']).to eq 'Original & 😀'
    expect(json['notification_type']).to eq 'status'
    expect(json['preferred_locale']).to eq 'ja'
  end
end
