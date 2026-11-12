# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GroupDirectory::CandidatePage do
  def page(params, search, limit: 2)
    described_class.new(
      viewer: nil,
      parsed: GroupDirectory::Parameters.parse!(params),
      limit: limit,
      search: search
    )
  end

  def hits_of(*ids)
    ids.map { |id| { id: id, sort: [id] } }
  end

  it 'applies offset after candidates are dropped' do
    calls = []
    search = lambda do |search_after:, size:|
      calls << [search_after, size]
      start = search_after.nil? ? 1 : search_after.first + 1
      hits_of(*(start..(start + size - 1)).to_a)
    end
    allow(GroupDirectory::Visibility).to receive(:keep) do |ids:, **|
      ids.select(&:even?)
    end
    stub_const("#{described_class}::BATCH", 4)

    expect(page({}, search, limit: 2).results).to eq([2, 4])
    expect(calls.first.last).to eq(4)
  end

  it 'returns a short page when the index is exhausted inside the scan budget' do
    search = lambda do |search_after:, size:|
      search_after.nil? ? hits_of(1, 2) : []
    end
    allow(GroupDirectory::Visibility).to receive(:keep).and_return([])
    stub_const("#{described_class}::BATCH", 2)
    stub_const("#{described_class}::MAX_SCAN", 2)

    expect(page({ limit: 5 }, search, limit: 5).results).to eq([])
  end

  it 'fails closed when another candidate exists past the scan budget' do
    search = lambda do |search_after:, size:|
      origin = search_after.nil? ? 0 : search_after.first
      hits_of(*(origin + 1..(origin + size)).to_a)
    end
    allow(GroupDirectory::Visibility).to receive(:keep).and_return([])
    stub_const("#{described_class}::BATCH", 2)
    stub_const("#{described_class}::MAX_SCAN", 2)

    expect { page({}, search, limit: 1).results }.to raise_error(GroupDirectory::SearchUnavailable) { |error|
      expect(error.reason).to eq('candidate scan limit')
    }
  end

  it 'fails closed when a page of candidates repeats' do
    search = lambda do |search_after:, size:|
      hits_of(4)
    end
    allow(GroupDirectory::Visibility).to receive(:keep) { |ids:, **| ids }
    stub_const("#{described_class}::BATCH", 1)

    expect { page({}, search, limit: 3).results }.to raise_error(GroupDirectory::SearchUnavailable) { |error|
      expect(error.reason).to eq('repeated elasticsearch page')
    }
  end
end
