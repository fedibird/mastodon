# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GroupDirectory::FollowingSearch do
  def parsed
    GroupDirectory::Parameters.parse!(scope: 'following')
  end

  it 'stops visibility checks once the page is filled' do
    searches = 0
    checked = []
    stub_const("#{described_class}::CHUNK", 1)
    search = lambda do |extra_filter:, **|
      searches += 1
      id = extra_filter.dig(:terms, :id).first
      [{ id: id, sort: [id] }]
    end
    allow(GroupDirectory::Visibility).to receive(:keep) do |ids:, **|
      checked.concat(ids)
      ids
    end

    GroupDirectory::SearchBudget.current = GroupDirectory::SearchBudget.new(clock: -> { 0 })
    page = described_class.new(
      viewer: nil,
      parsed: parsed,
      limit: 1,
      search: search,
      ids: [1, 2, 3]
    ).results

    expect(page).to eq([3])
    expect(searches).to eq(3)
    expect(checked).to eq([3])
  ensure
    GroupDirectory::SearchBudget.current = nil
  end

  it 'does not return a page when the budget expires after the database check' do
    now = 0
    GroupDirectory::SearchBudget.current = GroupDirectory::SearchBudget.new(clock: -> { now })
    search = lambda do |extra_filter:, **|
      [{ id: extra_filter.dig(:terms, :id).first, sort: [1] }]
    end
    allow(GroupDirectory::Visibility).to receive(:keep) do |ids:, **|
      now = 10
      ids
    end
    stub_const('GroupDirectory::SearchBudget::MAX_ELAPSED', 1)

    expect do
      described_class.new(
        viewer: nil,
        parsed: parsed,
        limit: 1,
      search: search,
      ids: [4]
    ).results
    end.to raise_error(GroupDirectory::SearchUnavailable) { |error|
      expect(error.reason).to eq('search budget')
    }
  ensure
    GroupDirectory::SearchBudget.current = nil
  end
end
