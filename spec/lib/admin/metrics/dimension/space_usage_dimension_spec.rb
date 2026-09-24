# frozen_string_literal: true

require 'rails_helper'

describe Admin::Metrics::Dimension::SpaceUsageDimension do
  subject(:dimension) { described_class.new(Time.utc(2026, 9, 19), Time.utc(2026, 9, 22), nil, nil) }

  it 'returns postgresql, redis, and media sizes in bytes' do
    allow(ActiveRecord::Base.connection).to receive(:execute).and_wrap_original do |method, sql, *args|
      if sql == 'SELECT pg_database_size(current_database())'
        [{ 'pg_database_size' => 2048 }]
      else
        method.call(sql, *args)
      end
    end
    allow(dimension).to receive(:redis_info).and_return({ 'used_memory' => '4096' })

    rows = dimension.data.index_by { |row| row[:key] }

    expect(rows.keys).to eq %w(postgresql redis media)
    expect(rows.values).to all(include(unit: 'bytes'))
    expect(rows['postgresql'][:value]).to eq '2048'
    expect(rows['redis'][:value]).to eq '4096'
    expect(rows['media'][:human_key]).to eq 'Media storage'
    expect(rows['media'][:human_key]).not_to include('translation missing')
  end
end
