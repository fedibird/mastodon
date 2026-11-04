# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FeedDelivery do
  describe '.mode' do
    around do |example|
      previous = ENV.fetch(described_class::MODE_ENV, nil)
      example.run
      ENV[described_class::MODE_ENV] = previous
    end

    it 'stays off when the variable is unset or unknown' do
      ENV.delete(described_class::MODE_ENV)
      expect(described_class.mode).to eq :off

      ENV[described_class::MODE_ENV] = 'yes'
      expect(described_class.mode).to eq :off
      expect(described_class.observe?).to be false
    end

    it 'accepts shadow and enforce' do
      ENV[described_class::MODE_ENV] = 'shadow'
      expect(described_class.shadow?).to be true
      expect(described_class.enforce?).to be false

      ENV[described_class::MODE_ENV] = 'enforce'
      expect(described_class.enforce?).to be true
    end
  end

  describe FeedDelivery::Evidence do
    let(:account) { Fabricate(:account) }
    let(:status) { Fabricate(:status, text: 'alpha is here') }
    let(:subscription) { KeywordSubscribe.create!(account: account, keyword: 'alpha', name: 'rule') }

    def evidence_for(status, subscription, ignore: nil)
      described_class.build(subscription: subscription, ignore_block_subscription: ignore, status: status)
    end

    it 'round-trips ids and generations without the keyword or the status text' do
      payload = evidence_for(status, subscription).to_options
      encoded = JSON.generate(payload)

      expect(encoded).not_to include('alpha')
      expect(encoded).not_to include(status.text)
      expect(payload['reason']).to eq 'keyword'
      expect(payload['evidence'].keys).to contain_exactly(
        'subscription_id',
        'subscription_updated_at',
        'account_id',
        'list_id',
        'status_id',
        'status_edited_at'
      )

      parsed = described_class.from_job_options(JSON.parse(encoded))
      expect(parsed).to be_fresh_for(status: status, account_id: account.id, list_id: nil, as_ignore_block: false)
    end

    it 'rejects unknown reasons, bad versions, and incomplete evidence' do
      valid = evidence_for(status, subscription).to_options

      expect(described_class.from_job_options({})).to be_nil
      expect(described_class.from_job_options(valid.merge('reason' => 'follow'))).to be_nil
      expect(described_class.from_job_options(valid.merge('reason' => 'nope'))).to be_nil
      expect(described_class.from_job_options(valid.merge('v' => 2))).to be_nil
      expect(described_class.from_job_options('reason' => 'keyword', 'v' => 1)).to be_nil

      broken = valid.deep_dup
      broken['evidence'].delete('status_edited_at')
      expect(described_class.from_job_options(broken)).to be_nil

      broken = valid.deep_dup
      broken['evidence']['subscription_id'] = 'abc'
      expect(described_class.from_job_options(broken)).to be_nil
    end

    it 'does not treat a missing ignore-block id as proof that none matched' do
      parsed = described_class.from_job_options(evidence_for(status, subscription).to_options)

      expect(parsed.ignore_block_subscription_id).to be_nil
      expect(parsed).not_to be_fresh_for(status: status, account_id: account.id, list_id: nil, as_ignore_block: true)
    end

    it 'drops the reply qualification when the subscription or the status edit changes' do
      evidence = evidence_for(status, subscription)
      expect(evidence).to be_fresh_for(status: status, account_id: account.id, list_id: nil, as_ignore_block: false)

      subscription.update!(keyword: 'beta')
      reloaded = described_class.from_job_options(evidence.to_options)
      expect(reloaded).not_to be_fresh_for(status: status.reload, account_id: account.id, list_id: nil, as_ignore_block: false)

      fresh = evidence_for(status, subscription.reload)
      status.update!(text: 'beta still', edited_at: Time.now.utc)
      reloaded = described_class.from_job_options(fresh.to_options)
      expect(reloaded).not_to be_fresh_for(status: status.reload, account_id: account.id, list_id: nil, as_ignore_block: false)
    end

    it 'keeps an ignore-block qualification only while that rule still has the flag' do
      ignore = KeywordSubscribe.create!(account: account, keyword: 'alpha', name: 'block', ignore_block: true, exclude_keyword: 'nope')
      evidence = evidence_for(status, subscription, ignore: ignore)

      expect(evidence).to be_fresh_for(status: status, account_id: account.id, list_id: nil, as_ignore_block: true)

      ignore.update!(ignore_block: false)
      reloaded = described_class.from_job_options(evidence.to_options)
      expect(reloaded).not_to be_fresh_for(status: status, account_id: account.id, list_id: nil, as_ignore_block: true)
      expect(reloaded).to be_fresh_for(status: status, account_id: account.id, list_id: nil, as_ignore_block: false)
    end
  end

  describe FeedDelivery::KeywordScan do
    let(:account) { Fabricate(:account) }
    let(:status) { Fabricate(:status, text: 'alpha beta') }
    let(:matching_text) { KeywordSubscribe::MatchingText.new(status: status) }

    it 'keeps the first match and a later ignore-block match' do
      first = KeywordSubscribe.create!(account: account, keyword: 'alpha', name: 'first')
      blocked = KeywordSubscribe.create!(account: account, keyword: 'beta', name: 'blocked', ignore_block: true, exclude_keyword: 'nope')
      KeywordSubscribe.create!(account: account, keyword: 'missing', name: 'other')

      evidence = described_class.collect([first, blocked], matching_text, status: status)

      expect(evidence.subscription_id).to eq first.id
      expect(evidence.ignore_block_subscription_id).to eq blocked.id
      expect(JSON.generate(evidence.to_options)).not_to include('alpha')
      expect(JSON.generate(evidence.to_options)).not_to include('beta')
    end

    it 'records one rule when that rule is both the reply match and the ignore-block match' do
      blocked = KeywordSubscribe.create!(account: account, keyword: 'alpha', name: 'blocked', ignore_block: true)

      evidence = described_class.collect([blocked], matching_text, status: status)

      expect(evidence.subscription_id).to eq blocked.id
      expect(evidence.ignore_block_subscription_id).to eq blocked.id
    end
  end

  describe FeedDelivery::InsertDecision do
    it 'cannot be constructed outside the filter pass' do
      expect { described_class.construct(filtered: false, list_admitted: true, timeline_type: :list) }
        .to raise_error(ArgumentError)
    end
  end

  describe FeedDelivery::Metrics do
    it 'counts only known fields' do
      described_class.reset!
      described_class.record('job|reason=keyword')
      described_class.record('kw|qual=reply|result=secret')

      expect(described_class.snapshot).to eq('job|reason=keyword' => 1)
    end
  end
end
