# frozen_string_literal: true

require 'rails_helper'

RSpec.describe RemoveStatusService, type: :service do # rubocop:disable Metrics/BlockLength
  subject { RemoveStatusService.new }

  let!(:alice)  { Fabricate(:account, user: Fabricate(:user)) }
  let!(:bob)    { Fabricate(:account, username: 'bob', domain: 'example.com') }
  let!(:jeff)   { Fabricate(:account) }
  let!(:hank)   { Fabricate(:account, username: 'hank', protocol: :activitypub, domain: 'example.com', inbox_url: 'http://example.com/inbox') }
  let!(:bill)   { Fabricate(:account, username: 'bill', protocol: :activitypub, domain: 'example2.com', inbox_url: 'http://example2.com/inbox') }

  before do
    stub_request(:post, 'http://example.com/inbox').to_return(status: 200)
    stub_request(:post, 'http://example2.com/inbox').to_return(status: 200)

    jeff.follow!(alice)
    hank.follow!(alice)

    @status = PostStatusService.new.call(alice, text: 'Hello @bob@example.com')
    FavouriteService.new.call(jeff, @status)
    Fabricate(:status, account: bill, reblog: @status, uri: 'hoge')
  end

  it 'removes status from author\'s home feed' do
    subject.call(@status)
    expect(HomeFeed.new(alice).get(10)).to_not include(@status.id)
  end

  it 'removes status from local follower\'s home feed' do
    subject.call(@status)
    expect(HomeFeed.new(jeff).get(10)).to_not include(@status.id)
  end

  it 'sends delete activity to followers' do
    subject.call(@status)
    expect(a_request(:post, 'http://example.com/inbox')).to have_been_made.twice
  end

  it 'sends delete activity to rebloggers' do
    subject.call(@status)
    expect(a_request(:post, 'http://example2.com/inbox')).to have_been_made
  end

  it 'remove status from notifications' do
    expect { subject.call(@status) }.to change {
      Notification.where(activity_type: 'Favourite', from_account: jeff, account: alice).count
    }.from(1).to(0)
  end

  it 'keeps delivering a direct delete to followers and mentioned remote accounts' do
    mentioned = Fabricate(:account, protocol: :activitypub, username: 'directbob', domain: 'direct.example', inbox_url: 'http://direct.example/inbox')
    follower = Fabricate(:account, protocol: :activitypub, username: 'directfan', domain: 'fan.example', inbox_url: 'http://fan.example/inbox')
    follower.follow!(alice)
    direct = Fabricate(:status, account: alice, visibility: :direct, text: 'secret')
    direct.mentions.create!(account: mentioned)

    captured = []
    allow(ActivityPub::DeliveryWorker).to receive(:push_bulk) { |inboxes| captured.concat(Array(inboxes)) }

    subject.call(direct)

    expect(captured).to include('http://direct.example/inbox', 'http://fan.example/inbox')
  end

  context 'when removed status is a reblog of a non-follower' do
    let!(:original_status) { Fabricate(:status, account: bill, text: 'Hello ThisIsASecret', visibility: :public) }
    let!(:status) { ReblogService.new.call(alice, original_status) }

    it 'sends Undo activity to followers' do
      subject.call(status)
      expect(a_request(:post, bill.inbox_url).with(
               body: hash_including({
                                      'type' => 'Undo',
                 'object' => hash_including({
                                              'type' => 'Announce',
                   'object' => ActivityPub::TagManager.instance.uri_for(original_status),
                                            }),
                                    })
             )).to have_been_made.once
    end
  end
end
