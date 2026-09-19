require 'rails_helper'

describe ReportFilter do
  describe 'with empty params' do
    it 'defaults to unresolved reports list' do
      filter = ReportFilter.new({})

      expect(filter.results).to eq Report.unresolved
    end
  end

  describe 'with invalid params' do
    it 'raises with key error' do
      filter = ReportFilter.new(wrong: true)

      expect { filter.results }.to raise_error(/wrong/)
    end
  end

  describe 'with valid params' do
    it 'combines filters on Report' do
      filter = ReportFilter.new(account_id: '123', resolved: true, target_account_id: '456')

      allow(Report).to receive(:where).and_return(Report.none)
      allow(Report).to receive(:resolved).and_return(Report.none)
      filter.results
      expect(Report).to have_received(:where).with(account_id: '123')
      expect(Report).to have_received(:where).with(target_account_id: '456')
      expect(Report).to have_received(:resolved)
    end

    it 'returns timestamp-resolved reports when resolved is true' do
      unresolved = Fabricate(:report, action_taken_at: nil)
      resolved = Fabricate(:report, action_taken_at: Time.now.utc)

      expect(ReportFilter.new(resolved: true).results).to include(resolved)
      expect(ReportFilter.new(resolved: true).results).not_to include(unresolved)
      expect(ReportFilter.new({}).results).to include(unresolved)
      expect(ReportFilter.new({}).results).not_to include(resolved)
    end

    it 'returns timestamp-resolved reports when resolved is 1' do
      unresolved = Fabricate(:report, action_taken_at: nil)
      resolved = Fabricate(:report, action_taken_at: Time.now.utc)

      expect(ReportFilter.new(resolved: '1').results).to include(resolved)
      expect(ReportFilter.new(resolved: '1').results).not_to include(unresolved)
    end

    it 'combines resolved with account_id and target_account_id' do
      reporter = Fabricate(:account)
      target = Fabricate(:account)
      matching = Fabricate(:report, account: reporter, target_account: target, action_taken_at: Time.now.utc)
      other_account = Fabricate(:report, target_account: target, action_taken_at: Time.now.utc)
      other_target = Fabricate(:report, account: reporter, action_taken_at: Time.now.utc)
      unresolved_match = Fabricate(:report, account: reporter, target_account: target, action_taken_at: nil)

      results = ReportFilter.new(
        resolved: true,
        account_id: reporter.id,
        target_account_id: target.id
      ).results

      expect(results).to include(matching)
      expect(results).not_to include(other_account)
      expect(results).not_to include(other_target)
      expect(results).not_to include(unresolved_match)
    end
  end
end
