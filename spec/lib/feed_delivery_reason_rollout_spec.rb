# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require_relative '../../script/feed_delivery_reason_rollout'

RSpec.describe FeedDeliveryReasonRollout do
  let(:prefix) { described_class::PREFIX }
  let(:first_key) { "#{prefix}:2026112314" }
  let(:second_key) { "#{prefix}:2026112315" }

  def snapshot(time:, phase: 'shadow', keys:)
    {
      'schema' => described_class::SCHEMA,
      'prefix' => prefix,
      'phase' => phase,
      'captured_at' => time,
      'keys' => keys,
    }
  end

  it 'subtracts hourly Redis hashes correctly across a UTC hour boundary' do
    before = snapshot(time: '2026-11-23T14:55:00Z', keys: {
      first_key => { 'job|reason=keyword' => 20, 'kw|qual=reply|result=agree' => 4 },
    })
    after = snapshot(time: '2026-11-23T15:05:00Z', keys: {
      first_key => { 'job|reason=keyword' => 25, 'kw|qual=reply|result=agree' => 7 },
      second_key => { 'job|reason=keyword' => 12, 'kw|qual=reply|result=agree' => 2 },
    })

    result = described_class.compare(before, after)

    expect(result['summary']).to include('keyword_jobs' => 17, 'reply_agree' => 5)
    expect(result['gate']['status']).to eq 'REVIEW_REQUIRED'
    expect(result['duration_seconds']).to eq 600
  end

  it 'blocks a shadow promotion when any disagreement or Redis persistence failure is observed' do
    before = snapshot(time: '2026-11-23T14:00:00Z', keys: { first_key => {} })
    after = snapshot(time: '2026-11-23T14:10:00Z', keys: { first_key => {
      'job|reason=keyword' => 100,
      'kw|qual=reply|result=agree' => 30,
      'kw|qual=ignore_block|result=disagree' => 1,
      'meta|result=persist_failure' => 1,
    } })

    result = described_class.compare(before, after)

    expect(result['gate']['status']).to eq 'BLOCKED'
    expect(result['gate']['reasons'].size).to eq 2
  end

  it 'reports insufficient sample sizes rather than declaring success' do
    before = snapshot(time: '2026-11-23T14:00:00Z', keys: { first_key => {} })
    after = snapshot(time: '2026-11-23T14:10:00Z', keys: { first_key => { 'job|reason=keyword' => 25 } })

    result = described_class.compare(before, after, min_jobs: 100, min_compared: 10)

    expect(result['gate']['status']).to eq 'INSUFFICIENT'
    expect(result['gate']['reasons']).to include('keyword jobs < 100', 'reply comparison samples < 10')
  end

  it 'refuses to compare different phases or an hour outside snapshot coverage' do
    before = snapshot(time: '2026-11-23T14:00:00Z', keys: { first_key => {} })
    after = snapshot(time: '2026-11-23T15:00:00Z', keys: { first_key => {}, second_key => {} })

    expect { described_class.compare(before, after.merge('phase' => 'enforce')) }
      .to raise_error(described_class::Error, /different phases/)
    expect { described_class.compare(before, after.merge('keys' => { second_key => {} })) }
      .to raise_error(described_class::Error, /hour coverage/)
  end

  it 'does not accept expired or reset counters as negative deltas' do
    before = snapshot(time: '2026-11-23T14:00:00Z', keys: { first_key => { 'job|reason=keyword' => 20 } })
    after = snapshot(time: '2026-11-23T14:05:00Z', keys: { first_key => { 'job|reason=keyword' => 5 } })

    expect { described_class.compare(before, after) }.to raise_error(described_class::Error, /negative counter/)
  end

  it 'never overwrites a snapshot file' do
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'snapshot.json')
      described_class.write_new_json(path, { 'a' => 1 })

      expect(File.stat(path).mode & 0o777).to eq 0o600
      expect { described_class.write_new_json(path, { 'a' => 2 }) }
        .to raise_error(described_class::Error, /will not overwrite/)
    end
  end
end
