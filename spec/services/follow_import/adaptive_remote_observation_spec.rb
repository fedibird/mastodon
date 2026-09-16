# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::AdaptiveRemoteObservation do
  def classify(**attrs)
    described_class.classify(**attrs)
  end

  def response(status)
    instance_double(HTTP::Response, code: status)
  end

  it 'classifies HTTP 2xx as success when status is present' do
    expect(classify(http_status: 200, request_started_at: Time.now.utc).event).to eq 'success'
    expect(classify(http_status: 201, request_started_at: Time.now.utc).event).to eq 'success'
  end

  it 'classifies HTTP 429 as rate_limit' do
    expect(classify(http_status: 429, request_started_at: Time.now.utc).event).to eq 'rate_limit'
  end

  it 'classifies HTTP 5xx as failure even when wrapped in UnexpectedResponseError' do
    error = Mastodon::UnexpectedResponseError.new(response(503))

    expect(classify(http_status: 503, error: error, request_started_at: Time.now.utc).event).to eq 'failure'
    expect(classify(error: error, request_started_at: Time.now.utc).event).to eq 'failure'
  end

  it 'classifies timeout and connection/SSL errors as failure' do
    started = Time.now.utc

    expect(classify(error: HTTP::TimeoutError.new, request_started_at: started).event).to eq 'failure'
    expect(classify(error: HTTP::ConnectionError.new, request_started_at: started).event).to eq 'failure'
    expect(classify(error: OpenSSL::SSL::SSLError.new, request_started_at: started).event).to eq 'failure'
  end

  it 'treats ordinary HTTP 4xx as neutral' do
    expect(classify(http_status: 404, request_started_at: Time.now.utc).event).to eq 'neutral'
    expect(classify(http_status: 410, request_started_at: Time.now.utc).event).to eq 'neutral'
  end

  it 'treats 3xx and unknown exceptions as neutral' do
    expect(classify(http_status: 301, request_started_at: Time.now.utc).event).to eq 'neutral'
    expect(classify(error: StandardError.new('boom'), request_started_at: Time.now.utc).event).to eq 'neutral'
  end

  it 'does not treat Stoplight-before-request as an adaptive failure' do
    result = classify(error: Stoplight::Error::RedLight.new('inbox'), request_started_at: nil)

    expect(result.event).to eq 'neutral'
    expect(result.request_reached).to be false
  end

  it 'prefers HTTP status over the exception class' do
    error = Mastodon::UnexpectedResponseError.new(response(429))

    expect(classify(http_status: 429, error: error, request_started_at: Time.now.utc).event).to eq 'rate_limit'
  end

  it 'does not classify from request duration or follow business state' do
    expect(described_class.instance_methods).not_to include(:request_duration_ms)
    expect(described_class.singleton_methods).not_to include(:from_follow_result)
    source = File.read(Rails.root.join('app/services/follow_import/adaptive_remote_observation.rb'))
    expect(source).not_to match(/Accept|Reject|Follow Gate|moderation|reputation/)
  end
end
