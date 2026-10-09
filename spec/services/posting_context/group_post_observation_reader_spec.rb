# frozen_string_literal: true

require 'rails_helper'

describe PostingContext::GroupPostObservationReader do
  subject { described_class.new }

  let(:author) { Fabricate(:user, admin: true).account }
  let(:group) do
    Fabricate(
      :account,
      username: 'technology',
      domain: 'lemmy.example',
      actor_type: 'Group',
      protocol: :activitypub,
      uri: 'https://lemmy.example/c/technology',
      inbox_url: 'https://lemmy.example/c/technology/inbox'
    )
  end
  let(:status) { Fabricate(:status, account: author, visibility: :public, text: 'Title line', audience_account: group) }
  let(:observation_key) { PostingContext::GroupFederationObservation.key_for(status.id, group.id) }

  before do
    Node.create!(domain: 'lemmy.example', info: { 'software_name' => 'lemmy' })
  end

  after do
    RedisConfiguration.with { |redis| redis.del(observation_key) }
  end

  def enable_observation
    ClimateControl.modify(
      GROUP_FEDERATION_OBSERVATION_ENABLED: 'true',
      GROUP_FEDERATION_OBSERVATION_AUTHOR_IDS: author.id.to_s
    ) { yield }
  end

  it 'reports a stored announce from the audience group only' do
    other_group = Fabricate(
      :account,
      username: 'other',
      domain: 'lemmy.example',
      actor_type: 'Group',
      protocol: :activitypub,
      uri: 'https://lemmy.example/c/other',
      inbox_url: 'https://lemmy.example/c/other/inbox'
    )
    person = Fabricate(:account, username: 'alice', domain: 'people.example', protocol: :activitypub, uri: 'https://people.example/users/alice', inbox_url: 'https://people.example/users/alice/inbox')
    Fabricate(:status, account: other_group, reblog: status, uri: 'https://lemmy.example/activities/other', text: '')
    Fabricate(:status, account: person, reblog: status, uri: 'https://people.example/activities/boost', text: '')

    result = subject.call(status)

    expect(result['group_announce']).to eq('observed' => false, 'evidence' => 'none')
    expect(result['remote_acceptance']).to eq 'unknown'
    expect(result['community_listing']).to eq 'not_verified'

    Fabricate(:status, account: group, reblog: status, uri: 'https://lemmy.example/activities/announce', text: '')

    found = subject.call(status)

    expect(found['group_announce']).to eq('observed' => true, 'evidence' => 'stored_reblog')
    expect(found['remote_acceptance']).to eq 'unknown'
    expect(found['community_listing']).to eq 'not_verified'
    expect(found['local_status']).to eq 'created'
  end

  it 'does not turn a missing record, HTTP 2xx, or announce into remote acceptance or a listing' do
    unknown = subject.call(status)

    expect(unknown['delivery_queue']).to eq 'unknown'
    expect(unknown['transport']).to include(
      'last_outcome' => nil,
      'http_status' => nil,
      'http_2xx_observed' => nil,
      'attempt_count' => nil,
      'terminal_failure_observed' => nil
    )
    expect(unknown['remote_acceptance']).to eq 'unknown'
    expect(unknown['group_announce']).to eq('observed' => false, 'evidence' => 'none')

    enable_observation do
      PostingContext::GroupFederationObservation.prepare(status, author)
      PostingContext::GroupFederationObservation.mark_queued(observation_key)
      PostingContext::GroupFederationObservation.apply_attempt(
        observation_key,
        'outcome' => 'http_success',
        'http_status' => 202,
        'http_attempt' => true,
        'http_2xx' => true,
        'request_started_at' => Time.now.utc.iso8601(6),
        'observed_at' => Time.now.utc.iso8601
      )
    end
    Fabricate(:status, account: group, reblog: status, uri: 'https://lemmy.example/activities/announce', text: '')

    result = subject.call(status)

    expect(result['adapter']).to eq 'lemmy_group'
    expect(result['delivery_queue']).to eq 'observed'
    expect(result['transport']).to include(
      'last_outcome' => 'http_success',
      'http_status' => 202,
      'http_2xx_observed' => true,
      'attempt_count' => 1,
      'terminal_failure_observed' => false
    )
    expect(result['group_announce']['observed']).to be true
    expect(result['remote_acceptance']).to eq 'unknown'
    expect(result['community_listing']).to eq 'not_verified'
    expect(result.to_json).not_to include(status.text)

    RedisConfiguration.with { |redis| redis.del(observation_key) }

    expired = subject.call(status)

    expect(expired['delivery_queue']).to eq 'unknown'
    expect(expired['transport']['http_2xx_observed']).to be_nil
    expect(expired['remote_acceptance']).to eq 'unknown'
    expect(expired['group_announce']).to eq('observed' => true, 'evidence' => 'stored_reblog')
  end

  it 'does not treat a non-group boost or another group announce as this group announce' do
    person = Fabricate(:account, username: 'bob', domain: 'people.example', protocol: :activitypub, uri: 'https://people.example/users/bob', inbox_url: 'https://people.example/users/bob/inbox')
    Fabricate(:status, account: person, reblog: status, uri: 'https://people.example/activities/boost', text: '')

    expect(subject.call(status)['group_announce']).to eq('observed' => false, 'evidence' => 'none')
  end
end
