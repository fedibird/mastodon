# frozen_string_literal: true

require 'rails_helper'
require 'timeout'

RSpec.describe PersonalEmojiSets::AddItem do
  self.use_transactional_tests = false

  let(:user) { Fabricate(:user) }
  let(:categories) do
    [{ 'id' => 'favorites', 'name' => 'Favorites', 'heading' => { 'mode' => 'first' }, 'items' => [{ 'id' => 'thumb', 'kind' => 'unicode', 'native' => '👍🏽', 'emoji_id' => '+1' }] }]
  end

  after do
    PersonalEmojiSet.where(user_id: user.id).delete_all
    Setting.unscoped.where(thing_type: 'User', thing_id: user.id).delete_all
    Account.where(id: user.account_id).delete_all
    User.where(id: user.id).delete_all
  end

  def add(emoji, revision: 1)
    described_class.new(user).call({ 'expected_revision' => revision, 'emoji' => emoji }, category_id: 'favorites')
  end

  it 'rolls back a failed append and does not publish a new revision' do
    PersonalEmojiSet.create!(user: user, revision: 1, categories: categories)
    allow_any_instance_of(PersonalEmojiSet).to receive(:update!).and_wrap_original do |method, *args, **kwargs|
      method.call(*args, **kwargs)
      raise 'failed after the append'
    end

    expect { add({ 'kind' => 'unicode', 'native' => '👍🏻' }) }.to raise_error('failed after the append')
    stored = PersonalEmojiSet.find_by!(user: user)
    expect(stored.revision).to eq 1
    expect(stored.categories.first.fetch('items').map { |item| item['native'] }).to eq ['👍🏽']
    expect(PersonalEmojiSets::PickerSize.current(user.id)).to eq 22
  end

  it 'serializes two adds on the user row so the stale writer cannot overwrite' do
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
        first_writer.call({ 'expected_revision' => 1, 'emoji' => { 'kind' => 'unicode', 'native' => '👍🏻' } }, category_id: 'favorites').added
      end
    end
    Timeout.timeout(5) { locked.pop }
    second = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        started << true
        described_class.new(User.find(user_id)).call({ 'expected_revision' => 1, 'emoji' => { 'kind' => 'unicode', 'native' => '👎' } }, category_id: 'favorites')
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
    expect(stored.categories.first.fetch('items').map { |item| item['native'] }).to eq ['👍🏽', '👍🏻']
  ensure
    release << true if release
    [first, second].compact.each { |thread| thread.kill if thread.alive? }
  end

  it 'does not let the first save and a revision-0 add both commit' do
    user_id = user.id
    locked = Queue.new
    release = Queue.new
    started = Queue.new
    saver = PersonalEmojiSets::Save.new(user)
    allow(saver).to receive(:lock_user).and_wrap_original do |method|
      record = method.call
      locked << true
      release.pop
      record
    end
    creation = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        saver.call(
          'expected_revision' => 0,
          'expected_picker_emoji_size' => 22,
          'picker_emoji_size' => 22,
          'categories' => categories
        ).revision
      end
    end
    Timeout.timeout(5) { locked.pop }
    addition = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        started << true
        described_class.new(User.find(user_id)).call(
          { 'expected_revision' => 0, 'emoji' => { 'kind' => 'unicode', 'native' => '👍🏻' } },
          category_id: 'favorites'
        )
      rescue PersonalEmojiSets::Conflict
        :conflict
      end
    end
    Timeout.timeout(5) { started.pop }
    release << true

    expect(creation.join(10)).to be creation
    expect(addition.join(10)).to be addition
    expect(creation.value).to eq 1
    expect(addition.value).to eq :conflict
    stored = PersonalEmojiSet.find_by!(user_id: user_id)
    expect(stored.revision).to eq 1
    expect(stored.categories.first.fetch('items').map { |item| item['native'] }).to eq ['👍🏽']
  ensure
    release << true if release
    [creation, addition].compact.each { |thread| thread.kill if thread.alive? }
  end

  it 'does not let an add and a full save overwrite each other' do
    PersonalEmojiSet.create!(user: user, revision: 1, categories: categories)
    user_id = user.id
    locked = Queue.new
    release = Queue.new
    started = Queue.new
    adder = described_class.new(user)
    allow(adder).to receive(:lock_user).and_wrap_original do |method|
      record = method.call
      locked << true
      release.pop
      record
    end
    addition = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        adder.call({ 'expected_revision' => 1, 'emoji' => { 'kind' => 'unicode', 'native' => '👍🏻' } }, category_id: 'favorites').document.revision
      end
    end
    Timeout.timeout(5) { locked.pop }
    replacement = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        started << true
        PersonalEmojiSets::Save.new(User.find(user_id)).call(
          'expected_revision' => 1,
          'expected_picker_emoji_size' => 22,
          'picker_emoji_size' => 22,
          'categories' => []
        )
      rescue PersonalEmojiSets::Conflict
        :conflict
      end
    end
    Timeout.timeout(5) { started.pop }
    release << true

    expect(addition.join(10)).to be addition
    expect(replacement.join(10)).to be replacement
    expect(addition.value).to eq 2
    expect(replacement.value).to eq :conflict
    stored = PersonalEmojiSet.find_by!(user_id: user_id)
    expect(stored.revision).to eq 2
    expect(stored.categories.first.fetch('items').map { |item| item['native'] }).to eq ['👍🏽', '👍🏻']
    expect(PersonalEmojiSets::PickerSize.current(user_id)).to eq 22
  ensure
    release << true if release
    [addition, replacement].compact.each { |thread| thread.kill if thread.alive? }
  end
end
