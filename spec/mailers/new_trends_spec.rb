# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AdminMailer, '.new_trends' do
  let(:recipient) { Fabricate(:account, username: 'mina', display_name: 'Mina', user: Fabricate(:user, locale: 'ja')) }
  let(:tag) { Fabricate(:tag, name: 'fedibird', display_name: 'Fedibird') }
  let(:card) { Fabricate(:preview_card, title: 'Link title', url: 'https://news.example/story', language: 'en') }
  let(:account) { Fabricate(:account, username: 'author') }
  let(:status) { Fabricate(:status, account: account, language: 'en', text: 'Hello') }

  before do
    PreviewCardTrend.create!(preview_card: card, score: 3.256, rank: 1, allowed: false, language: 'en')
    StatusTrend.create!(status: status, account: account, score: 4.2, rank: 1, allowed: false, language: 'en')
    redis.pfadd("activity:tags:#{tag.id}:#{Time.now.utc.beginning_of_day.to_i}:accounts", '1')
    redis.pfadd("activity:tags:#{tag.id}:#{1.day.ago.beginning_of_day.to_i}:accounts", '2')
    redis.zadd('trending_tags:all', 6.5, tag.id)
  end

  it 'renders a combined review mail in the recipient locale without calling Trends::History#get on tags' do
    mail = described_class.new_trends(recipient, [card], [tag], [status])

    expect(mail.to).to eq [recipient.user_email]
    expect(mail.subject).to eq("#{Rails.configuration.x.local_domain}で新しいトレンドが審査待ちです")

    body = mail.body.encoded
    expect(body).to include('以下の項目は、公開する前に審査が必要です。')
    expect(body).to include('トレンドリンク')
    expect(body).to include('Link title')
    expect(body).to include('https://news.example/story')
    expect(body).to include(admin_trends_links_url)
    expect(body).to include('トレンドハッシュタグ')
    expect(body).to include('#Fedibird')
    expect(body).to include(admin_trends_tags_url(status: 'pending_review'))
    expect(body).to include('トレンド投稿')
    expect(body).to include(ActivityPub::TagManager.instance.url_for(status))
    expect(body).to include(admin_trends_statuses_url)
    expect(body).not_to include('undefined method')
  end
end
