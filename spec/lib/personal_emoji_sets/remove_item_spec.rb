# frozen_string_literal: true

require 'rails_helper'
require 'timeout'

RSpec.describe PersonalEmojiSets::RemoveItem do
  self.use_transactional_tests = false

  let(:user) { Fabricate(:user) }
  let(:categories) do
    [
      {
        'id' => 'favorites',
        'name' => 'Favorites',
        'heading' => { 'mode' => 'emoji', 'item_id' => 'thumb' },
        'items' => [
          { 'id' => 'thumb', 'kind' => 'unicode', 'native' => '👍🏽', 'emoji_id' => '+1' },
          { 'id' => 'down', 'kind' => 'unicode', 'native' => '👎', 'emoji_id' => '-1' },
        ],
      },
    ]
  end

  after do
    PersonalEmojiSet.where(user_id: user.id).delete_all
    Setting.unscoped.where(thing_type: 'User', thing_id: user.id).delete_all
    Account.where(id: user.account_id).delete_all
    User.where(id: user.id).delete_all
  end

  def remove(emoji = { 'kind' => 'unicode', 'native' => '👍🏽' }, revision: 1)
    described_class.new(user).call({ 'expected_revision' => revision, 'emoji' => emoji }, category_id: 'favorites')
  end

  it 'rolls back a failed removal and keeps the representative' do
    PersonalEmojiSet.create!(user: user, revision: 1, categories: categories)
    allow_any_instance_of(PersonalEmojiSet).to receive(:update!).and_wrap_original do |method, *args, **kwargs|
      method.call(*args, **kwargs)
      raise 'failed after the removal'
    end

    expect { remove }.to raise_error('failed after the removal')
    stored = PersonalEmojiSet.find_by!(user: user)
    expect(stored.revision).to eq 1
    expect(stored.categories.first.dig('heading', 'item_id')).to eq 'thumb'
    expect(stored.categories.first.fetch('items').map { |item| item['id'] }).to eq %w(thumb down)
    expect(PersonalEmojiSets::PickerSize.current(user.id)).to eq 22
  end

  it 'serializes a removal against a stale append on the user row' do
    PersonalEmojiSet.create!(user: user, revision: 1, categories: categories)
    user_id = user.id
    locked = Queue.new
    release = Queue.new
    started = Queue.new
    first_writer = described_class.new(user)
    allow(first_writer).to receive(:lock_user).and_wrap_original do |method|
      record = method.call
      locked << true
      release.pop
      record
    end
    first = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        first_writer.call({ 'expected_revision' => 1, 'emoji' => { 'kind' => 'unicode', 'native' => '👍🏽' } }, category_id: 'favorites').removed
      end
    end
    Timeout.timeout(5) { locked.pop }
    second = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        started << true
        PersonalEmojiSets::AddItem.new(User.find(user_id)).call({ 'expected_revision' => 1, 'emoji' => { 'kind' => 'unicode', 'native' => '👍🏻' } }, category_id: 'favorites')
      rescue PersonalEmojiSets::Conflict
        :conflict
      end
    end
    Timeout.timeout(5) { started.pop }
    release << true

    expect(first.join(10)).to be first
    expect(second.join(10)).to be second
    expect(first.value).to be true
    expect(second.value).to eq :conflict
    stored = PersonalEmojiSet.find_by!(user_id: user_id)
    expect(stored.revision).to eq 2
    expect(stored.categories.first.fetch('items').map { |item| item['native'] }).to eq ['👎']
    expect(stored.categories.first.fetch('heading')).to eq('mode' => 'first')
  ensure
    release << true if release
    [first, second].compact.each { |thread| thread.kill if thread.alive? }
  end
end
