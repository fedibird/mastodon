# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'NodeBB group ActivityPub delivery' do # rubocop:disable Metrics/BlockLength
  let(:author) { Fabricate(:account, username: 'alice') }
  let(:group) { nodebb_category('category', 'nodebb.example') }
  let(:other_group) { nodebb_category('other', 'other-nodebb.example') }
  let(:follower) do
    Fabricate(
      :account,
      username: 'fan',
      domain: 'nodebb.example',
      protocol: :activitypub,
      uri: 'https://nodebb.example/user/fan',
      inbox_url: 'https://nodebb.example/user/fan/inbox',
      shared_inbox_url: 'https://nodebb.example/inbox'
    )
  end
  let(:mentioned) do
    Fabricate(
      :account,
      username: 'bob',
      domain: 'people.example',
      protocol: :activitypub,
      uri: 'https://people.example/users/bob',
      inbox_url: 'https://people.example/users/bob/inbox',
      shared_inbox_url: 'https://people.example/inbox'
    )
  end

  before do
    group
    other_group
    mentioned
    follower.follow!(author)
    stub_delivery!
  end

  it 'addresses a public Note to the category and delivers Create once to its actor inbox' do
    status = post_to_category('Hello @category@nodebb.example @bob@people.example')
    json = create_json(status)
    delivered = delivery_inboxes

    expect(status.visibility).to eq 'public'
    expect(status.audience_account).to eq group
    expect(status.reblogs).to be_empty
    expect(json['type']).to eq 'Create'
    expect(json['actor']).to eq ActivityPub::TagManager.instance.uri_for(author)
    expect(json['object']['type']).to eq 'Note'
    expect(json['object']['attributedTo']).to eq ActivityPub::TagManager.instance.uri_for(author)
    expect(json['object']['audience']).to eq group.uri
    expect(json['to']).to include('https://www.w3.org/ns/activitystreams#Public', group.uri)
    expect(json['object']['to']).to include('https://www.w3.org/ns/activitystreams#Public', group.uri)
    expect(json['to']).not_to include(group.followers_url, other_group.uri, other_group.followers_url)
    expect(json['cc']).not_to include(group.followers_url, other_group.uri)
    expect(mention_tag(json)).to include(
      'type' => 'Mention',
      'href' => group.uri,
      'name' => '@category@nodebb.example'
    )
    expect(group.inbox_url).not_to eq(group.shared_inbox_url)
    expect(delivered.count(group.inbox_url)).to eq 1
    expect(delivered).to include(group.inbox_url, group.shared_inbox_url, mentioned.inbox_url)
    expect(delivered).not_to include(group.followers_url, other_group.inbox_url, other_group.shared_inbox_url, mentioned.shared_inbox_url)
    expect(direct_inboxes).not_to include(group.inbox_url)
    expect(direct_inboxes.count(mentioned.inbox_url)).to eq 1
  end

  it 'keeps one copy when the category actor inbox is already a follower inbox' do
    follower.update!(inbox_url: group.inbox_url, shared_inbox_url: '')
    post_to_category('Hello @category@nodebb.example')

    expect(delivery_inboxes.count(group.inbox_url)).to eq 1
    expect(delivery_inboxes).not_to include(group.shared_inbox_url, group.followers_url)
  end

  it 'still delivers a category that is the audience but not a mention' do
    status = PostStatusService.new.call(author, text: 'Hello without a mention', visibility: :public, audience_account_id: group.id)

    expect(status.mentions.map(&:account)).not_to include(group)
    expect(delivery_inboxes.count(group.inbox_url)).to eq 1
    expect(delivery_inboxes).to include(group.shared_inbox_url)
    expect(delivery_inboxes).not_to include(group.followers_url)
  end

  it 'delivers Update and Delete to the category actor inbox without announcing as the group' do
    status = post_to_category('Hello @category@nodebb.example @bob@people.example')
    # Create serialization can build an unsaved status_stat on this instance
    # after the row exists. An edit loads the status again.
    status = Status.find(status.id)
    clear_delivery!

    UpdateStatusService.new.call(status, author.id, text: 'Edited @category@nodebb.example @bob@people.example')
    update_payload = @bulk_payloads.find { |row| row[2] == group.inbox_url }
    update_json = Oj.load(update_payload.first)

    expect(update_json['type']).to eq 'Update'
    expect(update_json['actor']).to eq ActivityPub::TagManager.instance.uri_for(author)
    expect(update_json['object']['type']).to eq 'Note'
    expect(update_json['object']['audience']).to eq group.uri
    expect(update_json['object']['attributedTo']).to eq ActivityPub::TagManager.instance.uri_for(author)
    expect(delivery_inboxes.count(group.inbox_url)).to eq 1
    expect(delivery_inboxes).to include('https://nodebb.example/inbox', mentioned.shared_inbox_url)
    expect(delivery_inboxes).not_to include(group.followers_url, other_group.inbox_url)
    expect(direct_inboxes).not_to include(group.inbox_url)

    clear_delivery!
    RemoveStatusService.new.call(status)

    expect(delivery_inboxes.count(group.inbox_url)).to eq 1
    expect(delivery_inboxes).not_to include(group.followers_url, other_group.inbox_url)
    expect(Status.where(reblog_of_id: status.id, account_id: group.id)).to be_empty
  end

  def nodebb_category(username, domain)
    Node.create!(domain: domain, info: { 'software_name' => 'nodebb' })
    Fabricate(
      :account,
      username: username,
      domain: domain,
      actor_type: 'Group',
      protocol: :activitypub,
      uri: "https://#{domain}/category/#{username}",
      inbox_url: "https://#{domain}/category/#{username}/inbox",
      shared_inbox_url: "https://#{domain}/inbox",
      followers_url: "https://#{domain}/category/#{username}/followers"
    )
  end

  def stub_delivery!
    @direct_calls = []
    @bulk_payloads = []
    allow(ActivityPub::DeliveryWorker).to receive(:perform_async) do |*args|
      @direct_calls << args
    end
    allow(ActivityPub::DeliveryWorker).to receive(:push_bulk) do |inboxes, &block|
      inboxes.each { |inbox| @bulk_payloads << block.call(inbox) } if block
      inboxes.each { |inbox| @bulk_payloads << [nil, nil, inbox] } unless block
    end
  end

  def clear_delivery!
    @direct_calls.clear
    @bulk_payloads.clear
  end

  def post_to_category(text)
    PostStatusService.new.call(author, text: text, visibility: :public, audience_account_id: group.id)
  end

  def direct_inboxes
    @direct_calls.map { |row| row[2] }
  end

  def delivery_inboxes
    direct_inboxes + @bulk_payloads.map { |row| row[2] }
  end

  def create_json(status)
    JSON.parse(ActiveModelSerializers::SerializableResource.new(ActivityPub::ActivityPresenter.from_status(status), serializer: ActivityPub::ActivitySerializer, adapter: ActivityPub::Adapter).to_json)
  end

  def mention_tag(json)
    json.dig('object', 'tag').find { |tag| tag['type'] == 'Mention' && tag['href'] == group.uri }
  end
end
