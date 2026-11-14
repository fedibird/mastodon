# frozen_string_literal: true

require 'rails_helper'

describe 'post draft races' do
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

  def payload(text)
    {
      'schema_version' => 1,
      'input' => { 'text' => text, 'privacy' => 'personal', 'media' => [] },
    }
  end

  it 'lets one of several concurrent creates pass the cap' do
    user = Fabricate(:user)
    threads = []
    stub_const('PostDraft::LIMIT', 1)
    outcomes = Queue.new
    threads = Array.new(3) do |index|
      Thread.new do
        with_connection do
          outcomes << PostDrafts::Store.new(Account.find(user.account_id)).create(
            client_uuid: "33333333-3333-4333-8333-33333333333#{index}",
            payload: payload("text #{index}")
          )
        end
      rescue StandardError => error
        outcomes << error
      end
    end
    finish(threads)
    results = Array.new(outcomes.size) { outcomes.pop }

    expect(results).to all(be_a(PostDrafts::Store::Result))
    expect(results.map(&:status).count(:created)).to eq 1
    expect(results.map(&:status).count(:limit)).to eq 2
    expect(PostDraft.where(account_id: user.account_id).count).to eq 1
  ensure
    finish(threads)
    cleanup(user)
  end

  it 'keeps one row when two creates use the same uuid' do
    user = Fabricate(:user)
    threads = []
    outcomes = Queue.new
    threads = Array.new(2) do
      Thread.new do
        with_connection do
          outcomes << PostDrafts::Store.new(Account.find(user.account_id)).create(
            client_uuid: '44444444-4444-4444-8444-444444444444',
            payload: payload('same')
          )
        end
      rescue StandardError => error
        outcomes << error
      end
    end
    finish(threads)
    results = Array.new(outcomes.size) { outcomes.pop }

    expect(results.map(&:status).sort).to eq [:created, :existing]
    expect(PostDraft.where(account_id: user.account_id).count).to eq 1
  ensure
    finish(threads)
    cleanup(user)
  end

  it 'lets only one update win the same revision' do
    user = Fabricate(:user)
    threads = []
    created = PostDrafts::Store.new(user.account).create(
      client_uuid: '55555555-5555-4555-8555-555555555555',
      payload: payload('start')
    )
    outcomes = Queue.new
    threads = %w(left right).map do |text|
      Thread.new do
        with_connection do
          outcomes << PostDrafts::Store.new(Account.find(user.account_id)).update(
            created.draft.id,
            expected_revision: 1,
            payload: payload(text)
          )
        end
      rescue StandardError => error
        outcomes << error
      end
    end
    finish(threads)
    results = Array.new(outcomes.size) { outcomes.pop }
    stored = PostDraft.find(created.draft.id)

    expect(results.map(&:status).sort).to eq [:conflict, :updated]
    expect(stored.revision).to eq 2
    expect(%w(left right)).to include(stored.payload.dig('input', 'text'))
  ensure
    finish(threads)
    cleanup(user)
  end
end
