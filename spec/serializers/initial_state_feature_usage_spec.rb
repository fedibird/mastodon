# frozen_string_literal: true

require 'rails_helper'

RSpec.describe InitialStateSerializer do
  def serialize(current_account)
    JSON.parse(
      ActiveModelSerializers::SerializableResource.new(
        InitialStatePresenter.new(current_account: current_account),
        serializer: described_class
      ).to_json,
      symbolize_names: true
    )
  end

  def capture_sql
    sqls = []
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |_name, _start, _finish, _id, payload|
      sqls << payload[:sql].to_s
    end
    yield
    sqls
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  def existence_probes(sqls, table)
    sqls.select { |sql| sql.match?(/SELECT 1 AS one FROM "#{table}"/i) }
  end

  def row_loads(sqls, table)
    sqls.select { |sql| sql.match?(/SELECT "#{table}"\.\*/i) }
  end

  it 'uses the existing account and user indexes for the existence probes' do
    expect(ActiveRecord::Base.connection.indexes(:circles).map(&:columns)).to include(['account_id'])
    expect(ActiveRecord::Base.connection.indexes(:lists).map(&:columns)).to include(['account_id'])
    user_index = ActiveRecord::Base.connection.indexes(:personal_emoji_sets).find { |index| index.columns == ['user_id'] }

    expect(user_index).to be_present
    expect(user_index.unique).to be true
  end

  it 'omits the hint for a guest and does not probe that viewer\'s tables' do
    json = nil
    sqls = capture_sql { json = serialize(nil) }

    expect(json).not_to have_key(:feature_usage)
    expect(existence_probes(sqls, 'circles')).to be_empty
    expect(existence_probes(sqls, 'lists')).to be_empty
    expect(existence_probes(sqls, 'personal_emoji_sets')).to be_empty
    expect(row_loads(sqls, 'circles')).to be_empty
    expect(row_loads(sqls, 'lists')).to be_empty
    expect(row_loads(sqls, 'personal_emoji_sets')).to be_empty
  end

  it 'reports absence for an unused account and does not load list or personal-set rows' do
    user = Fabricate(:user)
    other = Fabricate(:user)
    Fabricate(:circle, account: other.account)
    Fabricate(:list, account: other.account, title: 'Other')
    PersonalEmojiSet.create!(user: other, categories: [{ 'name' => 'Other' }], revision: 1)

    json = nil
    sqls = capture_sql { json = serialize(user.account) }
    circle_probes = existence_probes(sqls, 'circles')
    list_probes = existence_probes(sqls, 'lists')
    set_probes = existence_probes(sqls, 'personal_emoji_sets')

    expect(json[:feature_usage]).to eq(has_circles: false, has_lists: false, has_personal_emoji_set: false)
    expect(json[:lists]).to eq([])
    expect(circle_probes.size).to eq(1)
    expect(list_probes.size).to eq(1)
    expect(set_probes.size).to eq(1)
    expect(circle_probes.first).to include('account_id')
    expect(list_probes.first).to include('account_id')
    expect(set_probes.first).to include('user_id')
    expect(row_loads(sqls, 'lists')).to be_empty
    expect(row_loads(sqls, 'circles')).to be_empty
    expect(row_loads(sqls, 'personal_emoji_sets')).to be_empty
  end

  it 'keeps owned lists in the payload and treats an empty personal-set row as present' do
    user = Fabricate(:user)
    Fabricate(:circle, account: user.account, title: 'Family')
    list = Fabricate(:list, account: user.account, title: 'Reading')
    PersonalEmojiSet.create!(user: user, categories: [], revision: 0)
    Fabricate(:circle)
    Fabricate(:list, title: 'Someone else')

    json = nil
    sqls = capture_sql { json = serialize(user.account) }

    expect(json[:feature_usage]).to eq(has_circles: true, has_lists: true, has_personal_emoji_set: true)
    expect(json[:lists].map { |item| item[:title] }).to eq(['Reading'])
    expect(json[:lists].map { |item| item[:id] }).to eq([list.id.to_s])
    expect(json).not_to have_key(:circles)
    expect(existence_probes(sqls, 'circles').size).to eq(1)
    expect(existence_probes(sqls, 'lists').size).to eq(1)
    expect(existence_probes(sqls, 'personal_emoji_sets').size).to eq(1)
    expect(row_loads(sqls, 'lists').size).to eq(1)
    expect(row_loads(sqls, 'personal_emoji_sets')).to be_empty
    expect(row_loads(sqls, 'circles')).to be_empty
  end
end
