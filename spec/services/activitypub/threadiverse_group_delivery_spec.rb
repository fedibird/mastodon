# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Threadiverse group ActivityPub delivery' do # rubocop:disable Metrics/BlockLength
  %w(lemmy piefed).each do |software|
    context "when the community runs #{software}" do # rubocop:disable Metrics/BlockLength
      let(:author) { Fabricate(:account, username: 'alice') }
      let(:group) { community('technology', "#{software}.example", software) }
      let(:other_group) { community('other', "other-#{software}.example", software) }
      let(:follower) do
        Fabricate(
          :account,
          username: 'fan',
          domain: "#{software}.example",
          protocol: :activitypub,
          uri: "https://#{software}.example/u/fan",
          inbox_url: "https://#{software}.example/u/fan/inbox",
          shared_inbox_url: "https://#{software}.example/inbox"
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

      it 'addresses a public Note to the community and delivers Create once to its actor inbox' do
        status = post_to_community("Hello @technology@#{software}.example @bob@people.example")
        json = create_json(status)

        expect(status.visibility).to eq 'public'
        expect(status.audience_account).to eq group
        expect(status.reblogs).to be_empty
        expect(json['type']).to eq 'Create'
        expect(json['object']['type']).to eq 'Note'
        expect(json['object']).not_to have_key('name')
        expect(json['actor']).to eq ActivityPub::TagManager.instance.uri_for(author)
        expect(json['object']['attributedTo']).to eq ActivityPub::TagManager.instance.uri_for(author)
        expect(json['object']['audience']).to eq group.uri
        expect(json['to']).to include('https://www.w3.org/ns/activitystreams#Public', group.uri)
        expect(json['object']['to']).to include('https://www.w3.org/ns/activitystreams#Public', group.uri)
        expect(json['to']).not_to include(group.followers_url, other_group.uri, other_group.followers_url)
        expect(json['cc']).not_to include(group.followers_url, other_group.uri, other_group.followers_url)
        expect(mention_tag(json)).to include(
          'type' => 'Mention',
          'href' => group.uri,
          'name' => "@technology@#{software}.example"
        )
        expect(delivery_inboxes.count(group.inbox_url)).to eq 1
        expect(delivery_inboxes).to include(group.inbox_url, group.shared_inbox_url, mentioned.inbox_url)
        expect(delivery_inboxes).not_to include(group.followers_url, other_group.inbox_url, other_group.shared_inbox_url, mentioned.shared_inbox_url)
        expect(direct_inboxes).not_to include(group.inbox_url)
        expect(direct_inboxes.count(mentioned.inbox_url)).to eq 1
      end

      it 'delivers Update and Delete to the community actor inbox without announcing as the group' do
        status = post_to_community("Hello @technology@#{software}.example @bob@people.example")
        status = Status.find(status.id)
        clear_delivery!

        UpdateStatusService.new.call(status, author.id, text: "Edited @technology@#{software}.example @bob@people.example")
        update_payload = @bulk_payloads.find { |row| row[2] == group.inbox_url }
        update_json = Oj.load(update_payload.first)

        expect(update_json['type']).to eq 'Update'
        expect(update_json['object']['type']).to eq 'Note'
        expect(update_json['object']['audience']).to eq group.uri
        expect(update_json['actor']).to eq ActivityPub::TagManager.instance.uri_for(author)
        expect(delivery_inboxes.count(group.inbox_url)).to eq 1
        expect(delivery_inboxes).to include("https://#{software}.example/inbox", mentioned.shared_inbox_url)
        expect(delivery_inboxes).not_to include(group.followers_url, other_group.inbox_url)
        expect(direct_inboxes).not_to include(group.inbox_url)

        clear_delivery!
        RemoveStatusService.new.call(status)

        expect(delivery_inboxes.count(group.inbox_url)).to eq 1
        expect(delivery_inboxes).not_to include(group.followers_url, other_group.inbox_url)
        expect(Status.where(reblog_of_id: status.id, account_id: group.id)).to be_empty
      end
    end
  end

  def community(username, domain, software)
    Node.create!(domain: domain, info: { 'software_name' => software })
    Fabricate(
      :account,
      username: username,
      domain: domain,
      actor_type: 'Group',
      protocol: :activitypub,
      uri: "https://#{domain}/c/#{username}",
      inbox_url: "https://#{domain}/c/#{username}/inbox",
      shared_inbox_url: "https://#{domain}/inbox",
      followers_url: "https://#{domain}/c/#{username}/followers"
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

  def post_to_community(text)
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
