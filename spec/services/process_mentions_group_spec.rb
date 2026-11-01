# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ProcessMentionsService do
  before do
    allow(DistributionWorker).to receive(:perform_async)
    allow(ActivityPub::DistributionWorker).to receive(:perform_async)
    allow(ActivityPub::DeliveryWorker).to receive(:perform_async)
    allow(LocalNotificationWorker).to receive(:perform_async)
  end

  let(:author) { Fabricate(:user).account }

  def post(group, visibility: :public, text: nil)
    Fabricate(:status, account: author, visibility: visibility, text: text || "hello @#{group.username}")
  end

  it 'announces one public or unlisted mention after an accepted follow' do
    group = Fabricate(:account, username: 'localgroup', actor_type: 'Group')
    legacy = Fabricate(:user, account: Fabricate(:account, username: 'legacygroup', actor_type: 'Group')).account
    legacy.user.settings.default_privacy = 'unlisted'
    legacy.user.save!
    author.follow!(group)
    author.follow!(legacy)

    public_status = post(group)
    described_class.new.call(public_status)
    ActivityPub::GroupDistributionWorker.new.perform(public_status.id)
    expect(Status.where(account: group, reblog_of_id: public_status.id).count).to eq 1
    expect(Status.find_by(account: group, reblog_of_id: public_status.id).visibility).to eq 'public'
    expect(public_status.reload).not_to be_discarded

    unlisted = post(legacy, visibility: :unlisted)
    described_class.new.call(unlisted)
    expect(Status.find_by(account: legacy, reblog_of_id: unlisted.id).visibility).to eq 'unlisted'

    legacy_public = post(legacy, visibility: :public, text: 'pub @legacygroup')
    described_class.new.call(legacy_public)
    expect(Status.find_by(account: legacy, reblog_of_id: legacy_public.id).visibility).to eq 'unlisted'

    private_group = Fabricate(:user, account: Fabricate(:account, username: 'privategroup', actor_type: 'Group')).account
    private_group.user.settings.default_privacy = 'private'
    private_group.user.save!
    author.follow!(private_group)
    private_floor = post(private_group, text: 'pub @privategroup')
    described_class.new.call(private_floor)
    expect(Status.find_by(account: private_group, reblog_of_id: private_floor.id).visibility).to eq 'private'
  end

  it 'does not announce without a follow, during a follow request, or for closed visibilities' do
    group = Fabricate(:account, username: 'closedgroup', actor_type: 'Group')
    outsider = post(group)
    described_class.new.call(outsider)
    expect(Status.find_by(account: group, reblog_of_id: outsider.id)).to be_nil

    group.update!(locked: true)
    FollowService.new.call(author, group)
    expect(author.requested?(group)).to be true
    requested = post(group, text: 'waiting @closedgroup')
    described_class.new.call(requested)
    expect(Status.find_by(account: group, reblog_of_id: requested.id)).to be_nil
    expect(requested.reload).not_to be_discarded

    group.update!(locked: false)
    author.follow!(group)
    %w(private direct limited personal).each do |visibility|
      hidden = post(group, visibility: visibility, text: "#{visibility} @closedgroup")
      described_class.new.call(hidden)
      expect(Status.find_by(account: group, reblog_of_id: hidden.id)).to be_nil
      expect(hidden.reload).not_to be_discarded
    end
  end

  it 'delivers a remote group mention without a local announce' do
    remote_group = Fabricate(
      :account,
      username: 'remotegroup',
      domain: 'groups.example',
      actor_type: 'Group',
      protocol: :activitypub,
      uri: 'https://groups.example/users/remotegroup',
      inbox_url: 'https://groups.example/inbox'
    )
    author.follow!(remote_group)
    status = post(remote_group, text: 'hi @remotegroup@groups.example')

    described_class.new.call(status)

    expect(Status.find_by(account: remote_group, reblog_of_id: status.id)).to be_nil
    expect(ActivityPub::DeliveryWorker).to have_received(:perform_async)
    expect(status.reload).not_to be_discarded
  end

  it 'notifies a person and does not announce a silent group mention' do
    group = Fabricate(:account, username: 'quietgroup', actor_type: 'Group')
    person = Fabricate(:user, account: Fabricate(:account, username: 'spokenperson')).account
    author.follow!(group)
    status = Fabricate(:status, account: author, visibility: :unlisted, text: 'hello @spokenperson')
    status.mentions.create!(account: group, silent: true)

    described_class.new.call(status)

    expect(Status.find_by(account: group, reblog_of_id: status.id)).to be_nil
    expect(LocalNotificationWorker).to have_received(:perform_async).with(person.id, kind_of(Integer), 'Mention', 'mention')
    expect(status.mentions.find_by(account: group)).to be_silent
    expect(status.reload).not_to be_discarded
  end

  it 'does not turn a person mention into an announce' do
    person = Fabricate(:user).account
    status = Fabricate(:status, account: author, visibility: :public, text: "hi @#{person.username}")

    expect { described_class.new.call(status) }.not_to raise_error
    expect(Status.where(account: person, reblog_of_id: status.id)).to be_empty
  end
end