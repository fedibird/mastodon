# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::ObservationTime do
  it 'returns nil duration when either timestamp is missing' do
    now = Time.now.utc
    expect(described_class.duration_ms(nil, now)).to be_nil
    expect(described_class.duration_ms(now, nil)).to be_nil
  end

  it 'does not treat a missing interval as zero' do
    expect(described_class.duration_ms(nil, nil)).to be_nil
  end

  it 'returns nil for a backwards clock interval so 0 stays an observed zero' do
    later = Time.utc(2026, 9, 15, 12, 0, 1)
    earlier = Time.utc(2026, 9, 15, 12, 0, 0)
    expect(described_class.duration_ms(later, earlier)).to be_nil
  end

  it 'keeps a real zero when start and finish are the same instant' do
    now = Time.utc(2026, 9, 15, 12, 0, 0)
    expect(described_class.duration_ms(now, now)).to eq 0
  end

  it 'parses an ISO8601 enqueue timestamp' do
    time = Time.utc(2026, 9, 15, 12, 0, 0)
    expect(described_class.parse(time.iso8601(6))).to eq time
  end
end
