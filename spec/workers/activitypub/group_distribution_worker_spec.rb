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

  it 'keeps a group login default as the privacy floor and a person mention unchanged' do
    legacy_user = Fabricate(:user, account: Fabricate(:account, username: 'legacywithuser', actor_type: 'Group'))
    legacy_user.settings.default_privacy = 'unlisted'
    legacy_user.save!
    group = legacy_user.account
    author.follow!(group)
    status = mention_status(group, visibility: :public)

    described_class.new.perform(status.id)

    expect(Status.find_by(account: group, reblog_of_id: status.id).visibility).to eq 'unlisted'

    person = Fabricate(:user).account
    mentioned = Fabricate(:status, account: author, visibility: :public, text: "hi @#{person.username}")
    expect { ProcessMentionsService.new.call(mentioned) }.not_to raise_error
    expect(Status.where(account: person, reblog_of_id: mentioned.id)).to be_empty
  end
end
