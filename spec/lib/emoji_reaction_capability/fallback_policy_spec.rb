# frozen_string_literal: true

require 'rails_helper'

RSpec.describe EmojiReactionCapability::FallbackPolicy do
  describe '.normalize' do
    it 'keeps the three choices and maps everything else to allow' do
      expect(described_class.normalize('allow')).to eq 'allow'
      expect(described_class.normalize('ask')).to eq 'ask'
      expect(described_class.normalize('deny')).to eq 'deny'
      [nil, '', 'Allow', 'yes', 'grandfathered', true, false, 1].each do |raw|
        expect(described_class.normalize(raw)).to eq('allow'), raw.inspect
      end
    end
  end

  describe '.form_choices' do
    it 'omits ask while the picker dialog is absent' do
      expect(described_class.picker_confirmation_available?).to be false
      expect(described_class.form_choices).to eq %w(allow deny)
      expect(described_class.form_selectable?('ask')).to be false
      expect(described_class.form_selectable?('deny')).to be true
    end

    it 'offers ask when the picker can confirm it' do
      allow(described_class).to receive(:picker_confirmation_available?).and_return(true)

      expect(described_class.form_choices).to eq %w(allow ask deny)
      expect(described_class.form_selectable?('ask')).to be true
    end
  end

  describe '.read' do
    it 'is nil when the account has no user' do
      expect(described_class.read(Fabricate(:account))).to be_nil
    end
  end
end

RSpec.describe EmojiReactionCapability::FallbackPolicyConfig do
  before { described_class.reset_incomplete_warning! }

  def flags(enforce:, canonical: 'true', idempotent: 'true')
    {
      'EMOJI_REACTION_FALLBACK_POLICY_ENFORCE' => enforce,
      'EMOJI_REACTION_CANONICAL_WRITES' => canonical,
      'EMOJI_REACTION_IDEMPOTENT_RETRY' => idempotent,
    }
  end

  it 'is off unless enforce and both prerequisites are exactly true' do
    cases = [
      [nil, nil, nil, false],
      ['true', nil, nil, false],
      ['true', 'true', nil, false],
      ['true', nil, 'true', false],
      ['TRUE', 'true', 'true', false],
      ['1', 'true', 'true', false],
      [nil, 'true', 'true', false],
      ['true', 'true', 'true', true],
    ]
    cases.each do |enforce, canonical, idempotent, expected|
      ClimateControl.modify(flags(enforce: enforce, canonical: canonical, idempotent: idempotent)) do
        expect(described_class.effective?).to be(expected), [enforce, canonical, idempotent].inspect
      end
    end
  end

  it 'warns once when enforce is requested without both prerequisites' do
    expect(Rails.logger).to receive(:warn).once.with(described_class::WARNING)

    ClimateControl.modify(flags(enforce: 'true', canonical: nil, idempotent: 'true')) do
      2.times { expect(described_class.effective?).to be false }
    end
  end

  it 'does not warn when enforce is unset' do
    expect(Rails.logger).not_to receive(:warn)

    ClimateControl.modify(flags(enforce: nil, canonical: nil, idempotent: nil)) do
      described_class.effective?
    end
  end
end

RSpec.describe EmojiReactionCapability::FallbackConfirmation do
  it 'round-trips a payload and rejects another purpose, a tampered token, and an expired token' do
    payload = { 'v' => 1, 'jti' => SecureRandom.uuid, 'user_id' => 4 }
    token = described_class.issue(payload)

    expect(described_class.read(token)).to include('jti' => payload['jti'], 'user_id' => 4)
    other = described_class.verifier.generate(payload, purpose: :something_else)
    expect(described_class.read(other)).to be_nil
    expect(described_class.read(token.sub('a', 'b'))).to be_nil
    expect(described_class.read('not-a-token')).to be_nil

    travel 6.minutes do
      expect(described_class.read(token)).to be_nil
    end
  end

  it 'consumes a jti once under concurrent redemption' do
    jti = SecureRandom.uuid
    results = Queue.new
    threads = Array.new(2) do
      Thread.new { results << described_class.consume!(jti) }
    end
    threads.each(&:join)

    expect(results.size).to eq 2
    expect([results.pop, results.pop]).to contain_exactly(:ok, :replay)
    expect(described_class.consume!(jti)).to eq :replay
  end

  it 'raises and does not report success when Redis is down' do
    allow(RedisConfiguration).to receive(:with).and_raise(Redis::ConnectionError)

    expect { described_class.consume!(SecureRandom.uuid) }
      .to raise_error(Mastodon::EmojiReactionPolicyError) { |error|
        expect(error.http_status).to eq 503
        expect(error.error_code).to eq 'fallback_confirmation_unavailable'
        expect(error.message).to eq 'There was a temporary problem serving your request, please try again'
        expect(error.details).to be_nil
      }
  end
end
