# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Trends.request_review!' do
  def taxonomist(disabled: false, **account_attrs)
    role = UserRole.create!(
      name: "Review mail #{SecureRandom.hex(4)}",
      position: UserRole.maximum(:position).to_i + 1,
      permissions_as_keys: %w(manage_taxonomies)
    )
    user = user_with_role(role, account: Fabricate(:account, **account_attrs))
    user.update!(disabled: true) if disabled
    user
  end

  def silence_mail
    allow(AdminMailer).to receive(:new_trends).and_return(instance_double(ActionMailer::MessageDelivery, deliver_later!: true))
  end

  before do
    Setting.trends = true
    Setting.trendable_by_default = false
  end

  it 'does not review or mail when trends are disabled' do
    tag = Fabricate(:tag, name: 'quiet', trendable: false, reviewed_at: nil, requested_review_at: nil)
    redis.zadd('trending_tags:all', 5, tag.id)
    expect(Trends.links).not_to receive(:request_review)
    expect(AdminMailer).not_to receive(:new_trends)

    Setting.trends = false
    Trends.request_review!

    expect(tag.reload.requested_review_at).to be_nil
  end

  it 'does not review or mail when tags are trendable by default' do
    tag = Fabricate(:tag, name: 'open', trendable: false, reviewed_at: nil, requested_review_at: nil)
    redis.zadd('trending_tags:all', 5, tag.id)
    expect(AdminMailer).not_to receive(:new_trends)

    Setting.trendable_by_default = true
    Trends.request_review!

    expect(tag.reload.requested_review_at).to be_nil
  end

  it 'sends one combined mail and does not repeat it after the candidate is marked' do
    reviewer = taxonomist
    tag = Fabricate(:tag, name: 'once', display_name: 'Once', trendable: false, reviewed_at: nil)
    redis.zadd('trending_tags:all', 5, tag.id)
    mail = instance_double(ActionMailer::MessageDelivery, deliver_later!: true)

    expect(AdminMailer).to receive(:new_trends).once.with(reviewer.account, [], [tag], []).and_return(mail)

    Trends.request_review!
    expect(tag.reload.requested_review_at).to be_present

    Trends.request_review!
  end

  it 'mails a functional taxonomist who allows trend review and skips everyone else' do
    allowed = taxonomist
    opted_out = taxonomist
    opted_out.settings['notification_emails'] = opted_out.settings.notification_emails.merge('trends' => false)
    reports = user_with_role(
      UserRole.create!(name: "Reports #{SecureRandom.hex(3)}", position: UserRole.maximum(:position).to_i + 1, permissions_as_keys: %w(manage_reports))
    )
    disabled = taxonomist(disabled: true)
    suspended = taxonomist
    suspended.account.update!(suspended_at: Time.now.utc)
    memorial = taxonomist
    memorial.account.update!(memorial: true)
    moved = taxonomist
    moved.account.update!(moved_to_account_id: Fabricate(:account).id)
    everyone = Fabricate(:user)

    mail = instance_double(ActionMailer::MessageDelivery, deliver_later!: true)
    expect(AdminMailer).to receive(:new_trends).with(allowed.account, [], kind_of(Array), []).and_return(mail)
    expect(AdminMailer).not_to receive(:new_trends).with(opted_out.account, anything, anything, anything)
    expect(AdminMailer).not_to receive(:new_trends).with(reports.account, anything, anything, anything)
    expect(AdminMailer).not_to receive(:new_trends).with(disabled.account, anything, anything, anything)
    expect(AdminMailer).not_to receive(:new_trends).with(suspended.account, anything, anything, anything)
    expect(AdminMailer).not_to receive(:new_trends).with(memorial.account, anything, anything, anything)
    expect(AdminMailer).not_to receive(:new_trends).with(moved.account, anything, anything, anything)
    expect(AdminMailer).not_to receive(:new_trends).with(everyone.account, anything, anything, anything)

    tag = Fabricate(:tag, name: 'audience', trendable: false, reviewed_at: nil)
    redis.zadd('trending_tags:all', 8, tag.id)

    Trends.request_review!
  end

  it 'sends one mail containing only links when that is the only candidate' do
    reviewer = taxonomist
    card = Fabricate(:preview_card, url: 'https://only.example/a', title: 'Only link', language: 'en', trendable: nil)
    PreviewCardTrend.create!(preview_card: card, score: 10, rank: 1, allowed: false, language: 'en')
    mail = instance_double(ActionMailer::MessageDelivery, deliver_later!: true)

    expect(AdminMailer).to receive(:new_trends).with(reviewer.account, [card], [], []).and_return(mail)

    Trends.request_review!
    expect(PreviewCardProvider.find_by(domain: 'only.example').requested_review_at).to be_present
  end
end
