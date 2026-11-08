# frozen_string_literal: true

require 'rails_helper'
require 'timeout'

RSpec.describe PersonalEmojiSets::Save do
  self.use_transactional_tests = false

  let(:user) { Fabricate(:user) }
  let(:categories) do
    [{ 'id' => 'favorites', 'name' => 'Favorites', 'heading' => { 'mode' => 'emoji', 'item_id' => 'thumb' }, 'items' => [{ 'id' => 'thumb', 'kind' => 'unicode', 'native' => '👍🏽' }] }]
  end

  after do
    Setting.unscoped.where(thing_type: 'User', thing_id: user.id).delete_all
    Account.where(id: user.account_id).delete_all
    User.where(id: user.id).delete_all
  end

  def body(revision: 0, previous_size: 22, size: 32, categories: self.categories)
    { 'expected_revision' => revision, 'expected_picker_emoji_size' => previous_size, 'picker_emoji_size' => size, 'categories' => categories }
  end

  def stored_size
    Setting.unscoped.find_by(thing_type: 'User', thing_id: user.id, var: 'picker_emoji_size')
  end

  def save(**options)
    described_class.new(user).call(body(**options))
  end

  it 'saves the complete definition and the existing scalar setting together' do
    document = save

    expect(document.revision).to eq 1
    expect(document.picker_emoji_size).to eq 32
    expect(document.categories.first.fetch('items').first.fetch('native')).to eq '👍🏽'
    expect(PersonalEmojiSet.find_by!(user: user).categories).to eq document.categories
    expect(stored_size.value).to eq '32'
    expect(User.find(user.id).setting_picker_emoji_size).to eq '32'
    expect(PersonalEmojiSets::Document.read(user).as_json).to eq document.as_json
  end

  it 'supports saving and reloading an empty set without manufacturing a setting override' do
    document = save(categories: [], size: 22)

    expect(document.revision).to eq 1
    expect(document.stock_document).to eq(revision: 1, picker_emoji_size: 22, stock: { categories: [] })
    expect(stored_size).to be_nil
  end

  it 'preserves legacy string and integer size values when reading the editor' do
    user.settings['picker_emoji_size'] = '36'
    expect(PersonalEmojiSets::Document.read(user).picker_emoji_size).to eq 36
    expect(user.setting_picker_emoji_size).to eq '36'
    user.settings['picker_emoji_size'] = 40
    expect(PersonalEmojiSets::Document.read(user).picker_emoji_size).to eq 40
    expect(user.setting_picker_emoji_size).to eq 40
  end

  it 'does not write anything when the submitted definition or display size is invalid' do
    expect { save(categories: [{ 'id' => 'a', 'name' => '', 'items' => [] }]) }.to raise_error(PersonalEmojiSets::Invalid)
    expect { save(size: 49) }.to raise_error(PersonalEmojiSets::Invalid)
    expect { save(size: '32') }.to raise_error(PersonalEmojiSets::Invalid)
    expect(PersonalEmojiSet.where(user: user)).to be_empty
    expect(stored_size).to be_nil
  end

  it 'rejects a stale definition without partially updating the size or categories' do
    first = save

    expect { save(size: 48, categories: []) }.to raise_error(PersonalEmojiSets::Conflict)
    expect(PersonalEmojiSets::Document.read(user).as_json).to eq first.as_json
    expect(stored_size.value).to eq '32'
  end

  it 'rejects a stale size after a legacy form changes only that preference' do
    user.settings['picker_emoji_size'] = '28'

    expect { save(size: 48) }.to raise_error(PersonalEmojiSets::Conflict)
    expect(PersonalEmojiSet.where(user: user)).to be_empty
    expect(stored_size.value).to eq '28'
  end

  it 'does not advance a revision beyond the exact integer range of JSON clients' do
    PersonalEmojiSet.create!(user: user, revision: described_class::MAX_REVISION, categories: [])
    expect { save(revision: described_class::MAX_REVISION) }.to raise_error(PersonalEmojiSets::Invalid)
    expect(PersonalEmojiSet.find_by!(user: user).revision).to eq described_class::MAX_REVISION
    expect(stored_size).to be_nil
  end

  it 'rolls back both writes and never publishes the provisional display size to cache' do
    user.settings['picker_emoji_size'] = '22'
    cache_key = Setting.cache_key('picker_emoji_size', user)
    allow(PersonalEmojiSets::PickerSize).to receive(:write_legacy!).and_wrap_original do |method, *args|
      method.call(*args)
      expect(Rails.cache.read(cache_key)).to eq '22'
      raise 'failed after the size write'
    end

    expect { save(size: 48) }.to raise_error('failed after the size write')
    expect(PersonalEmojiSet.where(user: user)).to be_empty
    expect(stored_size.value).to eq '22'
    expect(Rails.cache.read(cache_key)).to eq '22'
    expect(PersonalEmojiSets::Document.read(user).revision).to eq 0
  end

  it 'does not let a delayed cache callback overwrite the newer committed size' do
    save(size: 28)
    old_setting = stored_size
    save(revision: 1, previous_size: 28, size: 44)
    old_setting.rewrite_cache

    expect(Rails.cache.read(Setting.cache_key('picker_emoji_size', user))).to eq '44'
    expect(user.setting_picker_emoji_size).to eq '44'
  end

  it 'reads the shared setting from its row so a stale cache fill cannot poison bootstrap' do
    save(size: 36)
    cache_key = Setting.cache_key('picker_emoji_size', user)
    Rails.cache.write(cache_key, '22')
    expect(Rails.cache).not_to receive(:fetch).with(cache_key)

    expect(User.find(user.id).setting_picker_emoji_size).to eq '36'
    expect(PersonalEmojiSets::Document.read(user).picker_emoji_size).to eq 36
  end

  it 'reports a committed save as successful even if refreshing the legacy cache fails' do
    user.settings['picker_emoji_size'] = '22'
    cache_key = Setting.cache_key('picker_emoji_size', user)
    allow(Rails.logger).to receive(:warn)
    allow(Rails.cache).to receive(:write).and_wrap_original do |method, key, *args|
      raise 'cache unavailable' if key == cache_key

      method.call(key, *args)
    end

    document = save(size: 40)
    expect(document.revision).to eq 1
    expect(document.picker_emoji_size).to eq 40
    expect(User.find(user.id).setting_picker_emoji_size).to eq '40'
    expect(Rails.logger).to have_received(:warn).with(include('Personal emoji picker size cache refresh failed'))
  end

  it 'serializes simultaneous initial saves on the existing user row and rejects one stale writer' do
    user_id = user.id
    payload = body
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
      ActiveRecord::Base.connection_pool.with_connection { first_writer.call(payload).revision }
    end
    Timeout.timeout(5) { locked.pop }
    second = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        started << true
        described_class.new(User.find(user_id)).call(payload)
      rescue PersonalEmojiSets::Conflict
        :conflict
      end
    end
    Timeout.timeout(5) { started.pop }
    release << true

    expect(first.join(10)).to be first
    expect(second.join(10)).to be second
    expect(first.value).to eq 1
    expect(second.value).to eq :conflict
    expect(PersonalEmojiSet.where(user_id: user_id).count).to eq 1
    expect(PersonalEmojiSet.find_by!(user_id: user_id).revision).to eq 1
  ensure
    release << true if release
    [first, second].compact.each { |thread| thread.kill if thread.alive? }
  end
end
