# frozen_string_literal: true

require 'rails_helper'

describe TimelineReadingBookmarks::Writer do
  self.use_transactional_tests = false

  def with_connection(&block)
    ActiveRecord::Base.connection_pool.with_connection(&block)
  end

  def cleanup_user(user)
    return if user&.id.nil?

    account_id = user.account_id
    TimelineReadingBookmark.where(user_id: user.id).delete_all
    User.where(id: user.id).find_each do |record|
      record.session_activations.delete_all
      record.destroy!
    end
    Account.where(id: account_id).find_each(&:destroy!)
  end

  def anchor
    {
      version: 1,
      status_id: '109717037387162260',
      offset_px: 1,
      alignment: 'top',
    }
  end

  it 'lets one of several concurrent creates pass the cap' do
    user = Fabricate(:user)
    stub_const('TimelineReadingBookmark::PER_USER_LIMIT', 1)
    outcomes = Queue.new
    threads = Array.new(3) do |index|
      Thread.new do
        with_connection do
          outcomes << described_class.new(User.find(user.id)).create(
            name: "Place #{index}",
            source: 'home',
            anchor: anchor
          )
        end
      rescue StandardError => e
        outcomes << e
      end
    end
    threads.each { |thread| thread.join(10) }
    results = Array.new(outcomes.size) { outcomes.pop }

    expect(results.count(&:ok?)).to eq(1)
    expect(results.reject(&:ok?).map(&:error).uniq).to eq(['limit'])
    expect(TimelineReadingBookmark.where(user_id: user.id).count).to eq(1)
  ensure
    threads&.each { |thread| thread.join(10) }
    cleanup_user(user)
  end

  it 'keeps one row when two creates use the same name' do
    user = Fabricate(:user)
    outcomes = Queue.new
    threads = Array.new(2) do
      Thread.new do
        with_connection do
          outcomes << described_class.new(User.find(user.id)).create(
            name: 'Same',
            source: 'home',
            anchor: anchor
          )
        end
      rescue StandardError => e
        outcomes << e
      end
    end
    threads.each { |thread| thread.join(10) }
    results = Array.new(outcomes.size) { outcomes.pop }

    expect(results.count(&:ok?)).to eq(1)
    expect(results.reject(&:ok?).map(&:error)).to eq(['duplicate_name'])
    expect(TimelineReadingBookmark.where(user_id: user.id).count).to eq(1)
  ensure
    threads&.each { |thread| thread.join(10) }
    cleanup_user(user)
  end

  it 'rejects the stale side of a concurrent rename' do
    user = Fabricate(:user)
    created = described_class.new(user).create(name: 'Original', source: 'home', anchor: anchor)
    version = created.bookmark.lock_version
    outcomes = Queue.new
    threads = %w(Alpha Beta).map do |name|
      Thread.new do
        with_connection do
          outcomes << described_class.new(User.find(user.id)).update(
            created.bookmark.id,
            name: name,
            lock_version: version
          )
        end
      rescue StandardError => e
        outcomes << e
      end
    end
    threads.each { |thread| thread.join(10) }
    results = Array.new(outcomes.size) { outcomes.pop }
    saved = TimelineReadingBookmark.find(created.bookmark.id)

    expect(results.count(&:ok?)).to eq(1)
    expect(results.reject(&:ok?).map(&:error)).to eq(['conflict'])
    expect(%w(Alpha Beta)).to include(saved.name)
    expect(saved.lock_version).to eq(version + 1)
  ensure
    threads&.each { |thread| thread.join(10) }
    cleanup_user(user)
  end
end
