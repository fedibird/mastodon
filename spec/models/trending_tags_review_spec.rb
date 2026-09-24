# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TrendingTags, '.notify_unreviewed!' do
  let(:reviewer) { user_with_role('Owner') }
  let(:tag) { Fabricate(:tag, name: 'needsreview', trendable: false) }

  before do
    allow(User).to receive(:those_who_can).with(:manage_taxonomies).and_return(User.where(id: reviewer.id))
  end

  it 'sends the existing trending-tag mail for a tag that would trend' do
    redis.zadd('trending_tags:all', 5, tag.id)
    mail = instance_double(ActionMailer::MessageDelivery, deliver_later!: true)

    expect(AdminMailer).to receive(:new_trending_tag).with(reviewer.account, tag).and_return(mail)
    expect(mail).to receive(:deliver_later!)

    described_class.notify_unreviewed!

    expect(tag.reload.requested_review_at).to be_present
  end

  it 'does not mail a tag that is already allowed to trend' do
    allowed = Fabricate(:tag, name: 'already', trendable: true)
    redis.zadd('trending_tags:all', 5, allowed.id)
    redis.zadd('trending_tags:allowed', 5, allowed.id)

    expect(AdminMailer).not_to receive(:new_trending_tag)

    described_class.notify_unreviewed!
  end
end
