# frozen_string_literal: true

require 'rails_helper'

RSpec.describe REST::StatusSerializer do
  describe '#updated_at' do
    let(:status) { Fabricate(:status, text: 'before') }

    it 'uses the newer status timestamp when the status stat is older' do
      stat = StatusStat.create!(status: status, created_at: 2.hours.ago, updated_at: 2.hours.ago)
      edited_at = Time.current.change(usec: 0)
      status.update_columns(text: 'after', updated_at: edited_at)

      expect(status.reload.updated_at).to be > stat.reload.updated_at
      expect(described_class.new(status).updated_at).to be >= status.updated_at
    end

    it 'uses the newer status stat timestamp when only interactions changed' do
      status.update_columns(updated_at: 2.hours.ago)
      stat = StatusStat.create!(status: status, created_at: 2.hours.ago, updated_at: Time.current.change(usec: 0))

      expect(described_class.new(status.reload).updated_at).to be >= stat.updated_at
    end

    it 'uses the status timestamp when no status stat exists' do
      edited_at = Time.current.change(usec: 0)
      status.update_columns(updated_at: edited_at)

      expect(described_class.new(status.reload).updated_at).to be_within(1.second).of(edited_at)
    end
  end
end
