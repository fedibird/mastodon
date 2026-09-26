# frozen_string_literal: true

require 'rails_helper'

RSpec.describe REST::StatusSerializer do
  let(:user) { Fabricate(:user) }
  let(:status) { Fabricate(:status, account: user.account) }

  before do
    status.status_stat.update!(favourites_count: 4, reblogs_count: 6)
    status.reload
  end

  def serialize(relationships = nil)
    options = {
      serializer: described_class,
      scope: user,
      scope_name: :current_user,
    }
    options[:relationships] = relationships if relationships

    JSON.parse(ActiveModelSerializers::SerializableResource.new(status, options).to_json, symbolize_names: true)
  end

  it 'prefers attributes_map counts, including an explicit zero' do
    relationships = StatusRelationshipsPresenter.new(
      [status],
      user.account.id,
      attributes_map: { status.id => { favourites_count: 0, reblogs_count: 2 } }
    )

    json = serialize(relationships)

    expect(json[:favourites_count]).to eq 0
    expect(json[:reblogs_count]).to eq 2
  end

  it 'falls back to the status counts when a key is absent' do
    relationships = StatusRelationshipsPresenter.new(
      [status],
      user.account.id,
      attributes_map: { status.id => { favourites_count: 1 } }
    )

    json = serialize(relationships)

    expect(json[:favourites_count]).to eq 1
    expect(json[:reblogs_count]).to eq 6
  end

  it 'uses the status counts when no attributes_map is provided' do
    relationships = StatusRelationshipsPresenter.new([status], user.account.id)
    json = serialize(relationships)

    expect(json[:favourites_count]).to eq 4
    expect(json[:reblogs_count]).to eq 6
  end
end
