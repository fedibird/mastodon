# frozen_string_literal: true

require 'rails_helper'

describe Admin::Metrics::Dimension::SourcesDimension do
  subject(:dimension) { described_class.new(start_at, end_at, limit, params) }

  let(:start_at) { Time.utc(2026, 9, 19) }
  let(:end_at)   { Time.utc(2026, 9, 22) }
  let(:limit)    { 10 }
  let(:params)   { ActionController::Parameters.new }

  it 'groups signups by oauth application and labels website signups' do
    travel_to Time.utc(2026, 9, 21, 12, 0, 0) do
      app = Fabricate(:application, name: 'Mobile')
      Fabricate(:user, created_at: Time.utc(2026, 9, 20, 9, 0, 0), created_by_application_id: app.id)
      Fabricate(:user, created_at: Time.utc(2026, 9, 20, 10, 0, 0), created_by_application_id: nil)

      expect(dimension.data).to include(
        { key: 'Mobile', human_key: 'Mobile', value: '1' },
        { key: 'web', human_key: 'Website', value: '1' }
      )
      expect(dimension.data.map { |row| row[:human_key] }.join).not_to include('translation missing')
    end
  end
end
