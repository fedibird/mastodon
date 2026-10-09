# frozen_string_literal: true

require 'rails_helper'

describe PostingContext::GroupDeliveryObserver do
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
  let(:status) { Fabricate(:status, account: author, visibility: :public, audience_account: group) }
  let(:observation_key) { PostingContext::GroupFederationObservation.key_for(status.id, group.id) }

  before do
    Node.create!(domain: 'lemmy.example', info: { 'software_name' => 'lemmy' })
    ClimateControl.modify(
      GROUP_FEDERATION_OBSERVATION_ENABLED: 'true',
      GROUP_FEDERATION_OBSERVATION_AUTHOR_IDS: author.id.to_s
    ) do
      PostingContext::GroupFederationObservation.prepare(status, author)
    end
  end

  after do
    RedisConfiguration.with { |redis| redis.del(observation_key) }
  end

  def record
    PostingContext::GroupFederationObservation.read(status.id, group.id)
  end

  def record_event(response: nil, error: nil, skip_reason: nil, request_started_at: nil)
    described_class.record_attempt(
      options: { 'group_delivery_observation' => observation_key },
      response: response,
      error: error,
      skip_reason: skip_reason,
      request_started_at: request_started_at
    )
  end

  it 'uses an HTTP response code even when a Stoplight error is also present' do
    record_event(response: double(code: 202), error: Stoplight::Error::RedLight.new('inbox'), request_started_at: Time.now.utc)

    expect(record['last_attempt_outcome']).to eq 'http_success'
    expect(record['last_http_status']).to eq 202
    expect(record['http_2xx_observed']).to be true
    expect(record['attempt_count']).to eq 1
    expect(record['terminal_failure_observed']).to be false
  end

  it 'does not count a Stoplight stop or a pre-send timeout or connection error' do
    record_event(error: Stoplight::Error::RedLight.new('inbox'))

    expect(record['last_attempt_outcome']).to eq 'circuit_interruption'
    expect(record['attempt_count']).to eq 0
    expect(record['last_http_status']).to be_nil

    record_event(error: HTTP::TimeoutError.new('early'))
    record_event(error: HTTP::ConnectionError.new('early'))
    record_event(error: OpenSSL::SSL::SSLError.new('early'))

    expect(record['attempt_count']).to eq 0
    expect(record['last_attempt_outcome']).to eq 'circuit_interruption'
    expect(record['http_2xx_observed']).to be false
  end

  it 'counts a timeout or connection error only after the send and keeps the last HTTP code' do
    started = Time.now.utc
    record_event(response: double(code: 202), request_started_at: started)

    record_event(error: HTTP::TimeoutError.new('late'), request_started_at: started + 1)
    expect(record['last_attempt_outcome']).to eq 'timeout'
    expect(record['last_http_status']).to eq 202
    expect(record['http_2xx_observed']).to be true
    expect(record['attempt_count']).to eq 2

    record_event(error: HTTP::ConnectionError.new('late'), request_started_at: started + 2)
    expect(record['last_attempt_outcome']).to eq 'connection_failure'
    expect(record['last_http_status']).to eq 202
    expect(record['http_2xx_observed']).to be true
    expect(record['attempt_count']).to eq 3

    view = PostingContext::GroupPostObservationReader.new.call(status)
    expect(view['transport']).to include(
      'last_outcome' => 'connection_failure',
      'http_status' => 202,
      'http_2xx_observed' => true,
      'attempt_count' => 3,
      'terminal_failure_observed' => false
    )
    expect(view['delivery_queue']).to eq 'observed'
    expect(view['remote_acceptance']).to eq 'unknown'
  end

  it 'does not treat a non-2xx response code as success' do
    record_event(response: double(code: '404'), request_started_at: Time.now.utc)

    expect(record['last_attempt_outcome']).to eq 'http_unsalvageable'
    expect(record['last_http_status']).to eq 404
    expect(record['http_2xx_observed']).to be false
    expect(record['attempt_count']).to eq 1
  end
end
