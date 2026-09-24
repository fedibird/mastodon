# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db', 'post_migrate', '20260924160000_remove_legacy_badge_settings.rb')

RSpec.describe RemoveLegacyBadgeSettings, type: :model do
  # Setting.where is forced to global rows by rails-settings. This model sees every row.
  class SettingRow < ActiveRecord::Base
    self.table_name = 'settings'
  end

  def insert_setting(var, thing_type: nil, thing_id: nil)
    SettingRow.insert!({
      var: var,
      value: YAML.dump(true),
      thing_type: thing_type,
      thing_id: thing_id,
      created_at: Time.current,
      updated_at: Time.current,
    })
  end

  it 'deletes only the global legacy badge rows' do
    insert_setting('show_staff_badge')
    insert_setting('show_moderator_badge')
    insert_setting('site_title')
    insert_setting('show_staff_badge', thing_type: 'User', thing_id: 1)
    insert_setting('show_moderator_badge', thing_type: 'User', thing_id: 1)

    described_class.new.up

    expect(SettingRow.where(var: 'show_staff_badge', thing_type: nil, thing_id: nil)).to be_empty
    expect(SettingRow.where(var: 'show_moderator_badge', thing_type: nil, thing_id: nil)).to be_empty
    expect(SettingRow.where(var: 'site_title', thing_type: nil, thing_id: nil)).to exist
    expect(SettingRow.where(var: 'show_staff_badge', thing_type: 'User', thing_id: 1)).to exist
    expect(SettingRow.where(var: 'show_moderator_badge', thing_type: 'User', thing_id: 1)).to exist
  end

  it 'does nothing on the way down' do
    insert_setting('show_staff_badge')
    described_class.new.up
    described_class.new.down

    expect(SettingRow.where(var: 'show_staff_badge', thing_type: nil, thing_id: nil)).to be_empty
  end
end
