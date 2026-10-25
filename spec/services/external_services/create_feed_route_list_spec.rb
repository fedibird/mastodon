# frozen_string_literal: true

require 'rails_helper'

# The race examples need committed rows and real concurrent connections, so
# this group runs outside the transaction wrapper and removes its own data.
RSpec.describe ExternalServices::CreateFeedRouteList do
  self.use_transactional_tests = false

  subject(:service) { described_class.new }

  let!(:user) { Fabricate(:user) }
  let!(:roommate) { share_account_user(user.account) }
  let(:account_id) { user.account_id }

  after do
    List.where(account_id: account_id).delete_all
    User.where(id: [user.id, roommate.id]).delete_all
    Account.where(id: account_id).delete_all
  end

  def seed_lists(count)
    now = Time.current
    List.insert_all!(Array.new(count) { |index| { account_id: account_id, title: "Seed #{index}", created_at: now, updated_at: now } })
  end

  def run_concurrently(callers)
    gate = Queue.new
    threads = callers.map do |caller|
      Thread.new do
        gate.pop
        ActiveRecord::Base.connection_pool.with_connection { caller.call }
      end
    end
    callers.size.times { gate << true }
    threads.map(&:value)
  end

  it 'creates a list for the account of the given user' do
    result = service.call(user: user, title: '  Morning   news ')

    expect(result.error).to be_nil
    expect(result.list).to have_attributes(account_id: account_id, title: 'Morning news')
  end

  it 'lets two users of one account share the list limit without exceeding it' do
    seed_lists(List::PER_ACCOUNT_LIMIT - 1)

    results = run_concurrently(
      [user, roommate, user, roommate, user, roommate].each_with_index.map do |owner, index|
        -> { described_class.new.call(user: owner, title: "Racer #{index}") }
      end
    )

    expect(List.where(account_id: account_id).count).to eq List::PER_ACCOUNT_LIMIT
    expect(results.count { |result| result.error.nil? }).to eq 1
    expect(results.filter_map(&:error).uniq).to eq [:limit]
  end

  it 'creates only one list when two users of one account submit the same name' do
    results = run_concurrently(
      [user, roommate, user, roommate].map do |owner|
        -> { described_class.new.call(user: owner, title: 'Same name') }
      end
    )

    expect(List.where(account_id: account_id, title: 'Same name').count).to eq 1
    expect(results.count { |result| result.error.nil? }).to eq 1
    expect(results.filter_map(&:error).uniq).to eq [:duplicate]
  end
end
