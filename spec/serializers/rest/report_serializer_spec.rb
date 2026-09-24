# frozen_string_literal: true

require 'rails_helper'

RSpec.describe REST::ReportSerializer do
  subject(:json) do
    JSON.parse(
      ActiveModelSerializers::SerializableResource.new(
        report,
        serializer: described_class
      ).to_json,
      symbolize_names: true
    )
  end

  let(:status) { Fabricate(:status) }
  let(:rule) { Fabricate(:rule, deleted_at: nil, priority: 0) }
  let(:report) do
    Fabricate(
      :report,
      target_account: status.account,
      status_ids: [status.id],
      category: :violation,
      comment: 'reasons',
      forwarded: false,
      rule_ids: [rule.id]
    )
  end

  it 'returns the Mastodon 4.2 report shape with string ids' do
    expect(json[:id]).to eq report.id.to_s
    expect(json[:id]).to be_a(String)
    expect(json[:action_taken]).to eq false
    expect(json[:action_taken_at]).to be_nil
    expect(json[:category]).to eq 'violation'
    expect(json[:comment]).to eq 'reasons'
    expect(json[:forwarded]).to eq false
    expect(json).to have_key(:created_at)
    expect(json[:status_ids]).to eq [status.id.to_s]
    expect(json[:status_ids]).to all(be_a(String))
    expect(json[:rule_ids]).to eq [rule.id.to_s]
    expect(json[:rule_ids]).to all(be_a(String))
    expect(json[:target_account][:id]).to eq status.account.id.to_s
  end

  it 'returns action_taken as true for a resolved report' do
    report.resolve!(Fabricate(:account))

    expect(json[:action_taken]).to eq true
    expect(json[:action_taken_at]).to be_present
  end
end

RSpec.describe REST::Admin::ReportSerializer do
  subject(:json) do
    JSON.parse(
      ActiveModelSerializers::SerializableResource.new(
        report,
        serializer: described_class
      ).to_json,
      symbolize_names: true
    )
  end

  let(:report) { Fabricate(:report, category: :spam, forwarded: false, comment: 'Spam') }

  it 'serializes the Mastodon 4.2 admin report shape for an unresolved report' do
    expect(json[:id]).to eq report.id.to_s
    expect(json[:id]).to be_a(String)
    expect(json[:action_taken]).to eq false
    expect(json[:action_taken_at]).to be_nil
    expect(json[:category]).to eq 'spam'
    expect(json[:comment]).to eq 'Spam'
    expect(json[:forwarded]).to eq false
    expect(json).to have_key(:created_at)
    expect(json).to have_key(:updated_at)
    expect(json).to have_key(:account)
    expect(json).to have_key(:target_account)
    expect(json).to have_key(:assigned_account)
    expect(json).to have_key(:action_taken_by_account)
    expect(json[:statuses]).to eq []
    expect(json[:rules]).to eq []
  end

  it 'serializes action_taken_at for a resolved report' do
    freeze_time do
      report.resolve!(Fabricate(:account))

      resolved_json = JSON.parse(
        ActiveModelSerializers::SerializableResource.new(
          report,
          serializer: described_class
        ).to_json,
        symbolize_names: true
      )

      expect(resolved_json[:action_taken]).to eq true
      expect(Time.zone.parse(resolved_json[:action_taken_at])).to be_within(1.second).of(Time.now.utc)
    end
  end

  it 'leaves forwarded as null when unset' do
    report.update!(forwarded: nil)

    expect(json[:forwarded]).to be_nil
  end

  it 'serializes discarded rules with string IDs' do
    rule = Fabricate(:rule, deleted_at: nil, priority: 0, text: 'Be kind')
    rule.discard
    report.update!(category: :violation, rule_ids: [rule.id])

    expect(json[:category]).to eq 'violation'
    expect(json[:rules].map { |entry| entry[:id] }).to eq [rule.id.to_s]
    expect(json[:rules].first[:id]).to be_a(String)
    expect(json[:rules].first[:text]).to eq 'Be kind'
  end
end
