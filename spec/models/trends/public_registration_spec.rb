# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Trends registration and refresh' do
  let(:account) { Fabricate(:account, username: 'trenduser', discoverable: true, trendable: true, silenced_at: nil) }

  def eligible_status(**options)
    Fabricate(:status, { account: account, visibility: :public, language: 'en', text: 'Hello world', sensitive: false, spoiler_text: '', reply: false }.merge(options))
  end

  it 'keeps tag history on the existing activity:tags redis keys' do
    tag = Fabricate(:tag, name: 'history', trendable: true)
    status = eligible_status(text: 'Hello #history')
    status.tags << tag

    tag.use!(account, status: status)

    day = Time.now.utc.beginning_of_day.to_i
    expect(redis.get("activity:tags:#{tag.id}:#{day}").to_i).to eq 1
    expect(redis.pfcount("activity:tags:#{tag.id}:#{day}:accounts")).to eq 1
  end

  it 'still records email domain block history on its own prefix' do
    history = Trends::History.new('email_domain_blocks', 99)
    history.add('192.0.2.10')

    day = Time.now.utc.beginning_of_day.to_i
    expect(redis.exists("activity:email_domain_blocks:99:#{day}")).to eq 1
    expect(history.get(Time.now.utc).uses).to eq 1
  end

  it 'refreshes a used tag into the allowed query' do
    tag = Fabricate(:tag, name: 'cats', trendable: true)
    6.times do |index|
      tag.use!(Fabricate(:account), status: eligible_status(text: "post #{index} #cats"))
    end

    Trends.tags.refresh(Time.now.utc)

    expect(Trends.tags.query.allowed.to_a).to include(tag)
  end

  it 'registers only public, non-sensitive, non-reply statuses and refreshes them' do
    status = eligible_status
    Fabricate(:status_stat, status: status, replies_count: 0, reblogs_count: 3, favourites_count: 3)
    private_status = eligible_status(visibility: :private, text: 'secret')
    direct_status = eligible_status(visibility: :direct, text: 'dm')
    sensitive_status = eligible_status(sensitive: true, text: 'sensitive')
    spoiler_status = eligible_status(spoiler_text: 'cw', text: 'hidden')
    reply_status = eligible_status(reply: true, text: 'reply')

    [status, private_status, direct_status, sensitive_status, spoiler_status, reply_status].each do |item|
      Trends.statuses.register(item)
    end
    Trends.statuses.refresh(Time.now.utc)

    ids = Trends.statuses.query.allowed.map(&:id)
    expect(ids).to eq [status.id]
  end

  it 'registers a link only from a public status whose card is an article' do
    status = eligible_status
    card = Fabricate(:preview_card, trendable: true, language: 'en', link_type: :article, title: 'Title', description: 'Body', provider_name: 'News', image_file_name: 'card.jpg', image_content_type: 'image/jpeg')
    status.preview_cards << card
    6.times { |index| card.history.add(Fabricate(:account).id) }

    Trends.links.register(status)
    Trends.links.refresh(Time.now.utc)

    expect(Trends.links.query.allowed.map(&:id)).to eq [card.id]

    private_status = eligible_status(visibility: :private)
    private_status.preview_cards << card
    expect { Trends.links.register(private_status) }.not_to raise_error
  end
end
