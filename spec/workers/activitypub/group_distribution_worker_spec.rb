# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ActivityPub::GroupDistributionWorker do
  before do
    allow(DistributionWorker).to receive(:perform_async)
    allow(ActivityPub::DistributionWorker).to receive(:perform_async)
    allow(ActivityPub::DeliveryWorker).to receive(:perform_async)
  end

  let(:author) { Fabricate(:user).account }

  def mention_status(group, visibility: :public)
    status = Fabricate(:status, account: author, visibility: visibility, text: "hello @#{group.username}")
    status.mentions.create!(account: group)
    status
  end

  it 'announces the original status for a user-less group when the author follows it' do
    group = Fabricate(:account, username: 'plainuserless', actor_type: 'Group', discoverable: true)
    author.follow!(group)
    status = mention_status(group, visibility: :unlisted)

    described_class.new.perform(status.id)

    boost = Status.find_by(account: group, reblog_of_id: status.id)
    expect(boost).to be_present
    expect(boost.visibility).to eq 'unlisted'
    expect(boost.reblog).to eq status
    expect(group.reload.user).to be_nil
  end

  it 'keeps a public original public for a user-less group and skips without a follow or a mention' do
    group = Fabricate(:account, username: 'publicuserless', actor_type: 'Group')
    author.follow!(group)
    public_status = mention_status(group, visibility: :public)
    described_class.new.perform(public_status.id)
    expect(Status.find_by(account: group, reblog_of_id: public_status.id).visibility).to eq 'public'

    quiet = Fabricate(:status, account: author, visibility: :public, text: 'no mention')
    described_class.new.perform(quiet.id)
    expect(Status.where(account: group).count).to eq 1

    outsider = Fabricate(:user).account
    other = Fabricate(:status, account: outsider, visibility: :public, text: "hey @#{group.username}")
    other.mentions.create!(account: group)
    described_class.new.perform(other.id)
    expect(Status.find_by(account: group, reblog_of_id: other.id)).to be_nil
  end

  it 'announces a remote post once for a followed local group and skips other visibilities' do
    group = Fabricate(:user, account: Fabricate(:account, username: 'legacywithuser', actor_type: 'Group')).account
    remote = Fabricate(
      :account,
      username: 'remoteauthor',
      domain: 'remote.example',
      protocol: :activitypub,
      uri: 'https://remote.example/users/remoteauthor',
      inbox_url: 'https://remote.example/inbox'
    )
    remote.follow!(group)
    status = Fabricate(:status, account: remote, visibility: :public, text: "hello @#{group.username}")
    status.mentions.create!(account: group)

    described_class.new.perform(status.id)
    described_class.new.perform(status.id)

    boosts = Status.where(account: group, reblog_of_id: status.id)
    expect(boosts.count).to eq 1
    expect(boosts.first.visibility).to eq 'public'
    expect(status.reload).not_to be_discarded

    %w(private direct limited personal).each do |visibility|
      hidden = Fabricate(:status, account: remote, visibility: visibility, text: "hidden @#{group.username}")
      hidden.mentions.create!(account: group)
      described_class.new.perform(hidden.id)
      expect(Status.find_by(account: group, reblog_of_id: hidden.id)).to be_nil
      expect(hidden.reload).not_to be_discarded
    end
  end

  it 'does not announce a remote post while only a follow request exists' do
    group = Fabricate(:account, username: 'lockedremote', actor_type: 'Group', locked: true)
    remote = Fabricate(
      :account,
      username: 'requestor',
      domain: 'remote.example',
      protocol: :activitypub,
      uri: 'https://remote.example/users/requestor',
      inbox_url: 'https://remote.example/inbox'
    )
    FollowService.new.call(remote, group)
    expect(remote.requested?(group)).to be true
    status = Fabricate(:status, account: remote, visibility: :public, text: "please @#{group.username}")
    status.mentions.create!(account: group)

    described_class.new.perform(status.id)

    expect(Status.find_by(account: group, reblog_of_id: status.id)).to be_nil
  end
end
