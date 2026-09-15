# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::FairnessCursor do
  subject(:store) { described_class.new }

  it 'returns a default empty cursor when nothing is stored' do
    state = store.read

    expect(state.source).to eq 'default'
    expect(state.last_owner_key).to be_nil
    expect(state.last_batch_by_owner).to eq({})
  end

  it 'round-trips reconstructable cursor state' do
    written = described_class::State.new(
      last_owner_key: 'a:2',
      last_batch_by_owner: { 'a:2' => 9 },
      last_position_by_batch: { '9' => 4 },
      source: 'redis'
    )

    expect(store.write(written)).to be true
    read = store.read

    expect(read.source).to eq 'redis'
    expect(read.last_owner_key).to eq 'a:2'
    expect(read.last_batch_by_owner).to eq('a:2' => 9)
    expect(read.last_position_by_batch).to eq('9' => 4)
  end

  it 'resets to stable-order default when Redis read fails' do
    allow(store).to receive(:redis).and_raise(Redis::BaseError, 'down')

    state = store.read

    expect(state.source).to eq 'reset'
    expect(state.last_owner_key).to be_nil
  end

  it 'does not raise when Redis write fails' do
    allow(store).to receive(:redis).and_raise(Redis::BaseError, 'down')

    expect(store.write(described_class::State.empty)).to be false
  end
end
