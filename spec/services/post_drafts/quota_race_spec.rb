# frozen_string_literal: true

require 'rails_helper'

describe 'post draft quota races' do
  self.use_transactional_tests = false

  def with_connection(&block)
    ActiveRecord::Base.connection_pool.with_connection(&block)
  end

  def finish(threads)
    Array(threads).compact.each { |thread| thread.join(10) }
  end

  def cleanup(user)
    return if user&.id.nil?

    PostDraft.where(account_id: user.account_id).delete_all
    user.session_activations.delete_all
    account_id = user.account_id
    user.destroy!
    Account.where(id: account_id).find_each(&:destroy!)
  end

  it 'lets one of several concurrent near-limit creates pass the cap' do
    user = Fabricate(:user)
    threads = []
    stub_const('PostDraft::LIMIT', 2)
    payload = PostDraftByteBudget.under(account_id: user.account_id, uuid: '17171717-1717-4171-8171-171717171717')
    outcomes = Queue.new
    threads = Array.new(3) do |index|
      Thread.new do
        with_connection do
          outcomes << PostDrafts::Store.new(Account.find(user.account_id)).create(
            client_uuid: format('18181818-1818-4181-8181-%012x', index),
            payload: payload
          )
        end
      rescue StandardError => e
        outcomes << e
      end
    end
    finish(threads)
    results = Array.new(outcomes.size) { outcomes.pop }
    rows = PostDraft.where(account_id: user.account_id)
    total = rows.pick(Arel.sql('coalesce(sum(octet_length(payload::text)), 0)')).to_i

    expect(results).to all(be_a(PostDrafts::Store::Result))
    expect(results.map(&:status).count(:created)).to eq 2
    expect(results.map(&:status).count(:limit)).to eq 1
    expect(rows.count).to eq 2
    expect(total).to be <= 2 * PostDrafts::Payload::MAX_BYTES
    expect(total).to be > PostDrafts::Payload::MAX_BYTES
  ensure
    finish(threads)
    cleanup(user)
  end
end
