# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20260924200000_move_trending_tag_notification_setting.rb')

RSpec.describe MoveTrendingTagNotificationSetting do
  def insert_emails(user, hash)
    Setting.unscoped.where(thing_type: 'User', thing_id: user.id, var: 'notification_emails').delete_all
    Setting.unscoped.insert!({
      var: 'notification_emails',
      value: hash.to_yaml,
      thing_type: 'User',
      thing_id: user.id,
      created_at: Time.current,
      updated_at: Time.current,
    })
  end

  def stored_emails(user)
    raw = Setting.unscoped.where(thing_type: 'User', thing_id: user.id, var: 'notification_emails').pick(:value)
    raw.present? ? YAML.unsafe_load(raw) : nil
  end

  let(:user) { Fabricate(:user) }

  before { Rails.cache.clear }

  it 'copies trending_tag true onto trends and drops the old key' do
    insert_emails(user, { 'follow' => false, 'trending_tag' => true })

    described_class.new.up

    expect(stored_emails(user)).to eq('follow' => false, 'trends' => true)
    Rails.cache.clear
    expect(user.settings.notification_emails['trends']).to be true
  end

  it 'preserves a stored false instead of falling back to the new default' do
    insert_emails(user, { 'trending_tag' => false })

    described_class.new.up

    expect(stored_emails(user)).to eq('trends' => false)
    Rails.cache.clear
    expect(user.settings.notification_emails['trends']).to be false
  end

  it 'leaves a row without either key unchanged so the new default stays true' do
    insert_emails(user, { 'follow' => true })
    before = Setting.unscoped.where(thing_type: 'User', thing_id: user.id, var: 'notification_emails').pick(:updated_at, :value)

    described_class.new.up

    after = Setting.unscoped.where(thing_type: 'User', thing_id: user.id, var: 'notification_emails').pick(:updated_at, :value)
    expect(after).to eq(before)
    Rails.cache.clear
    expect(user.settings.notification_emails['trends']).to be true
  end

  it 'does not let the old key overwrite an existing trends value' do
    insert_emails(user, { 'trending_tag' => false, 'trends' => true })

    described_class.new.up

    expect(stored_emails(user)).to eq('trends' => true)
  end

  it 'round-trips false back to trending_tag' do
    insert_emails(user, { 'trending_tag' => false, 'mention' => true })

    described_class.new.up
    described_class.new.down

    expect(stored_emails(user)).to eq('mention' => true, 'trending_tag' => false)
  end
end
