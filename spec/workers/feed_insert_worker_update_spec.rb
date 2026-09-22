# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FeedInsertWorker do
  let(:author) { Fabricate(:account, username: 'author') }
  let(:follower_account) { Fabricate(:account, username: 'follower') }
  let!(:follower) { Fabricate(:user, account: follower_account, current_sign_in_at: Time.now.utc) }
  let(:status) { Fabricate(:status, account: author, text: 'already home', visibility: :public) }

  before do
    follower
    follower_account.follow!(author, notify: true)
  end

  it 'inserts the status once and does not send a status notification for an update' do
    allow(NotifyService).to receive(:new)

    described_class.new.perform(status.id, follower_account.id, 'home', { 'update' => true })
    described_class.new.perform(status.id, follower_account.id, 'home', { 'update' => true })

    expect(HomeFeed.new(follower_account).get(20).map(&:id).count(status.id)).to eq 1
    expect(NotifyService).not_to have_received(:new)
  end
end
