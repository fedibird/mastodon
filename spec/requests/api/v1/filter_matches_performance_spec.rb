# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Filter matches batch query budget' do
  it 'keeps SQL bounded for 100 different remote authors with media, polls, references and reblogs' do
    viewer = Fabricate(:user)
    token = Fabricate(:accessible_access_token, resource_owner_id: viewer.id, scopes: 'read:statuses read:filters')
    record = Fabricate(:custom_filter, account: viewer.account)
    Fabricate(:custom_filter_keyword, custom_filter: record, keyword: 'batchword', whole_word: false)
    originals = Array.new(50) do |i|
      author = Fabricate(:account, domain: "batch#{i}.example")
      status = Fabricate(:status, account: author, text: '<p>batchword</p>')
      Fabricate(:media_attachment, account: author, status: status, remote_url: 'https://media.example/test.jpg', file: nil, description: 'altword')
      poll = Fabricate(:poll, account: author, status: status)
      status.update!(poll_id: poll.id)
      status
    end
    originals.each_cons(2) { |status, reference| Fabricate(:status_reference, status: status, target_status: reference) }
    wrappers = originals.map { |status| Fabricate(:status, reblog: status) }
    ids = (originals + wrappers).map { |status| status.id.to_s }
    headers = { 'Authorization' => "Bearer #{token.token}" }

    # Warm framework/schema/auth paths; use a fresh filter cache for both samples.
    post '/api/v1/fedibird/filters/matches', params: { status_ids: [] }, headers: headers, as: :json
    [ids.first(1), ids].each do |batch|
      Rails.cache.clear
      queries = []
      callback = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] unless payload[:name] == 'SCHEMA' || payload[:cached] || payload[:sql].match?(/\A(?:BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/) }
      elapsed = Benchmark.realtime do
        ActiveRecord::Base.uncached do
          ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
            post '/api/v1/fedibird/filters/matches', params: { status_ids: batch }, headers: headers, as: :json
          end
        end
      end
      expect(response).to have_http_status(200)
      body = JSON.parse(response.body)
      expect(body['matches'].keys).to eq(batch)
      expect(body['matches'].values).to all(eq([record.id.to_s]))
      expect(body['unavailable']).to eq([])
      expect(queries.size).to be <= 35
      puts "Filter matches measurement: ids=#{batch.size} SQL=#{queries.size} bytes=#{response.body.bytesize} elapsed_ms=#{(elapsed * 1000).round(1)}"
    end
  end
end
