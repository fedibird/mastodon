# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GroupDirectory::SearchBudget do
  it 'stops after the call cap or the elapsed cap' do
    calls = described_class.new(clock: -> { 0 })
    stub_const("#{described_class}::MAX_CALLS", 1)
    calls.track!
    expect { calls.track! }.to raise_error(GroupDirectory::SearchUnavailable) { |error|
      expect(error.reason).to eq('search budget')
    }

    now = 0
    stub_const("#{described_class}::MAX_CALLS", 5)
    stub_const("#{described_class}::MAX_ELAPSED", 1)
    elapsed = described_class.new(clock: -> { now })
    elapsed.track!
    now = 2
    expect { elapsed.track! }.to raise_error(GroupDirectory::SearchUnavailable)
  end
end
