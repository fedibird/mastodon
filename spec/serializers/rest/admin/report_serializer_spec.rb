# frozen_string_literal: true

require 'rails_helper'

describe REST::Admin::ReportSerializer do
  it 'serializes reported statuses through the current cache includes' do
    author = Fabricate(:account)
    mentioned = Fabricate(:account)
    statuses = Array.new(2) do
      status = Fabricate(:status, account: author, text: "hello @#{mentioned.username}")
      Fabricate(:media_attachment, account: author, status: status)
      Fabricate(:mention, account: mentioned, status: status)
      status
    end
    report = Fabricate(:report, target_account: author, status_ids: statuses.map(&:id))

    relation = report.statuses.with_includes

    expect(relation).to be_a(ActiveRecord::Relation)
    expect(relation.map(&:id)).to match_array(statuses.map(&:id))

    queries = []
    callback = lambda do |*_args, payload|
      queries << payload[:sql]
    end

    json = nil
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      json = JSON.parse(described_class.new(report).to_json)
    end

    serialized = json['statuses']
    expect(serialized.map { |row| row['id'] }).to match_array(statuses.map { |status| status.id.to_s })
    expect(serialized).to all(include('media_attachments' => be_present, 'mentions' => be_present))

    association_selects = queries.select { |sql| sql.match?(/\ASELECT/i) && sql.match?(/"(status_stats|media_attachments|mentions)"/) }
    point_lookups = association_selects.grep(/"status_id"\s*=/)

    expect(association_selects).not_to be_empty
    expect(point_lookups).to be_empty
  end
end
