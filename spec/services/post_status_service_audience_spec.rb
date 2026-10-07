# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PostStatusService, type: :service do # rubocop:disable Metrics/BlockLength
  subject { described_class.new }

  before do
    allow(ActivityPub::DeliveryWorker).to receive(:push_bulk)
    allow(ActivityPub::DeliveryWorker).to receive(:perform_async)
  end

  def remote_group(username: 'group', domain: 'group.example', inbox_url: nil, shared_inbox_url: nil)
    Fabricate(
      :account,
      username: username,
      domain: domain,
      actor_type: 'Group',
      protocol: :activitypub,
      uri: "https://#{domain}/users/#{username}",
      inbox_url: inbox_url || "https://#{domain}/users/#{username}/inbox",
      shared_inbox_url: shared_inbox_url || "https://#{domain}/inbox",
      followers_url: "https://#{domain}/users/#{username}/followers"
    )
  end

  it 'persists a public audience target without mentioning the group' do
    account = Fabricate(:account)
    group = remote_group
    text = 'Hello from the timeline'

    status = subject.call(account, text: text, visibility: :public, audience_account_id: group.id)

    expect(status).to be_persisted
    expect(status.audience_account).to eq group
    expect(status.text).to eq text
    expect(status.visibility).to eq 'public'
    expect(status.mentions.map(&:account)).not_to include(group)
    expect(Mention.where(account: group, status: status)).to be_empty
  end

  it 'accepts an unlisted audience target' do
    account = Fabricate(:account)
    group = remote_group

    status = subject.call(account, text: 'Quiet hello', visibility: :unlisted, audience_account_id: group.id.to_s)

    expect(status.audience_account).to eq group
    expect(status.visibility).to eq 'unlisted'
    expect(status.mentions).to be_empty
  end

  it 'keeps a public audience target when silence downgrades it to unlisted' do
    account = Fabricate(:account)
    account.silence!
    group = remote_group

    status = subject.call(account, text: 'Silenced hello', visibility: :public, audience_account_id: group.id)

    expect(status.visibility).to eq 'unlisted'
    expect(status.audience_account).to eq group
  end

  it 'rejects an audience target when hard silence downgrades the post to private' do
    account = Fabricate(:account)
    account.hard_silence!
    group = remote_group

    expect do
      subject.call(account, text: 'Hard silenced', visibility: :public, audience_account_id: group.id)
    end.to raise_error(Mastodon::ValidationError, I18n.t('statuses.errors.invalid_audience_visibility'))

    expect(Status.where(text: 'Hard silenced')).to be_empty
  end

  it 'rejects a person, a local group, and a non-ActivityPub group' do
    account = Fabricate(:account)
    person = Fabricate(:account, username: 'alice', domain: 'people.example', actor_type: 'Person', protocol: :activitypub, uri: 'https://people.example/users/alice', inbox_url: 'https://people.example/users/alice/inbox')
    local_group = Fabricate(:account, username: 'localgroup', actor_type: 'Group')
    ostatus_group = Fabricate(:account, username: 'oldgroup', domain: 'ostatus.example', actor_type: 'Group', protocol: :ostatus, uri: 'https://ostatus.example/users/oldgroup', inbox_url: 'https://ostatus.example/users/oldgroup/inbox')

    [person, local_group, ostatus_group].each do |target|
      expect do
        subject.call(account, text: 'Nope', visibility: :public, audience_account_id: target.id)
      end.to raise_error(Mastodon::ValidationError, I18n.t('statuses.errors.invalid_audience_account'))
    end

    expect(Status.where(text: 'Nope')).to be_empty
  end

  it 'rejects private, direct, limited, mutual, and personal audience targets' do
    account = Fabricate(:account)
    group = remote_group

    %i(private direct limited mutual personal).each do |visibility|
      expect do
        subject.call(account, text: "Nope #{visibility}", visibility: visibility, audience_account_id: group.id)
      end.to raise_error(Mastodon::ValidationError, I18n.t('statuses.errors.invalid_audience_visibility'))
    end

    expect(Status.where(account: account)).to be_empty
  end

  it 'rejects an audience target on a reply' do
    account = Fabricate(:account)
    parent = Fabricate(:status, account: account, visibility: :public)
    group = remote_group

    expect do
      subject.call(account, text: 'Reply', visibility: :public, thread: parent, audience_account_id: group.id)
    end.to raise_error(Mastodon::ValidationError, I18n.t('statuses.errors.audience_on_reply'))

    expect(Status.where(text: 'Reply')).to be_empty
  end

  it 'rejects an unknown audience account' do
    account = Fabricate(:account)

    expect do
      subject.call(account, text: 'Missing', visibility: :public, audience_account_id: 99_999_999_999_999)
    end.to raise_error(ActiveRecord::RecordNotFound)

    expect(Status.where(text: 'Missing')).to be_empty
  end

  it 'leaves an ordinary post without an audience target' do
    account = Fabricate(:account)

    status = subject.call(account, text: 'Ordinary', visibility: :public)

    expect(status.audience_account).to be_nil
    expect(status.text).to eq 'Ordinary'
  end

  it 'keeps the saved audience target when the status is edited' do
    account = Fabricate(:account)
    group = remote_group
    status = subject.call(account, text: 'Hello', visibility: :public, audience_account_id: group.id)

    UpdateStatusService.new.call(status, account.id, text: 'Hello edited')

    expect(status.reload.text).to eq 'Hello edited'
    expect(status.audience_account).to eq group
    expect(status.mentions.map(&:account)).not_to include(group)
  end

  it 'stores the audience target on a scheduled status and publishes it later' do
    account = Fabricate(:account)
    group = remote_group
    scheduled = subject.call(account, text: 'Hello later', visibility: :public, audience_account_id: group.id, scheduled_at: 1.hour.from_now)

    expect(scheduled).to be_a(ScheduledStatus)
    expect(scheduled.params['audience_account_id']).to eq group.id
    expect(scheduled.params).to have_key('audience_account_id')
    expect(account.statuses.find_by(text: 'Hello later')).to be_nil

    PublishScheduledStatusWorker.new.perform(scheduled.id)

    status = account.statuses.find_by!(text: 'Hello later')
    json = JSON.parse(ActiveModelSerializers::SerializableResource.new(status, serializer: ActivityPub::NoteSerializer, adapter: ActivityPub::Adapter).to_json)

    expect(status.audience_account).to eq group
    expect(status.mentions).to be_empty
    expect(json['audience']).to eq group.uri
    expect(json['to']).to include('https://www.w3.org/ns/activitystreams#Public', group.uri)
  end

  it 'nullifies the audience target when the group account is deleted' do
    account = Fabricate(:account)
    group = remote_group
    status = subject.call(account, text: 'Hello', visibility: :public, audience_account_id: group.id)

    group.destroy!

    expect(status.reload.audience_account_id).to be_nil
  end
end
