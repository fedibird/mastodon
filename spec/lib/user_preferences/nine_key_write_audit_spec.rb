# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('script/settings_service_catalog/nine_key_write_audit')

RSpec.describe SettingsServiceCatalog::NineKeyWriteAudit do
  subject(:audit) { described_class.new(Rails.root) }

  def details(result, key)
    result[key].map(&:detail)
  end

  it 'accepts the repository and only the pinned dynamic writes' do
    result = audit.call

    expect(result['ok']).to be true
    expect(result['violations']).to eq []
    expect(result['unlisted_reviews']).to eq []
    expect(result['scanned_files']).to be > 1000
    expect(result['allowed_reviews'].size).to eq described_class::ALLOW.size
    expect(result['allowed_reviews'].map(&:path)).to include(
      'app/lib/user_settings_decorator.rb',
      'app/lib/user_preferences/writer.rb',
      'app/lib/settings/scoped_settings.rb'
    )
  end

  it 'detects literal, dynamic, and read-only fixtures' do
    literal = audit.scan_content('app/services/example_preference_write.rb', <<~RUBY)
      user.settings['default_privacy'] = 'direct'
    RUBY
    dynamic = audit.scan_content('app/services/example_dynamic_write.rb', <<~RUBY)
      user.settings[key] = value
    RUBY
    update_all = audit.scan_content('app/services/example_update_all.rb', <<~RUBY)
      Setting.where(
        thing_type: 'User',
        var: 'default_privacy'
      ).update_all(value: 'direct')
    RUBY
    create = audit.scan_content('app/services/example_create.rb', <<~RUBY)
      Setting.create!(
        thing_type: 'User',
        thing_id: user.id,
        var: 'default_privacy',
        value: 'direct'
      )
    RUBY
    setter = audit.scan_content('app/services/example_setter.rb', <<~RUBY)
      user.settings.public_send(:default_privacy=, 'direct')
    RUBY
    unscoped = audit.scan_content('app/services/example_unscoped.rb', <<~RUBY)
      Setting.unscoped.where(thing_type: 'User', var: key).update_all(value: value)
    RUBY
    insert_all = audit.scan_content('app/services/example_insert.rb', <<~RUBY)
      Setting.insert_all([{ var: 'default_privacy', value: 'direct' }])
    RUBY
    upsert_all = audit.scan_content('app/services/example_upsert.rb', <<~RUBY)
      Setting.upsert_all([{ var: name }])
    RUBY
    multiline = audit.scan_content('app/services/example_multiline.rb', <<~RUBY)
      user.settings[
        'default_privacy'
      ] = 'direct'
    RUBY
    dynamic_setter = audit.scan_content('app/services/example_dynamic_setter.rb', <<~RUBY)
      user.settings.public_send(:"\#{name}=", value)
    RUBY
    sql = audit.scan_content('app/services/example_sql.rb', <<~RUBY)
      ActiveRecord::Base.connection.execute("UPDATE settings SET value = 'x' WHERE var = 'default_privacy'")
    RUBY
    other = audit.scan_content('app/services/example_other_setting.rb', <<~RUBY)
      user.settings['disable_post'] = true
      value = user.settings['default_privacy']
      Setting.unscoped.where(thing_type: 'User', var: 'default_privacy')
    RUBY

    expect(details(literal, 'violations')).to eq ['default_privacy']
    expect(literal['allowed_reviews']).to eq []
    expect(details(dynamic, 'reviews')).to eq ['dynamic index']
    expect(dynamic['unlisted_reviews'].size).to eq 1
    expect(details(update_all, 'violations')).to eq ['default_privacy']
    expect(details(create, 'violations')).to eq ['default_privacy']
    expect(details(setter, 'violations')).to eq ['default_privacy']
    expect(unscoped['violations']).to eq []
    expect(unscoped['unlisted_reviews'].size).to eq 1
    expect(details(insert_all, 'violations')).to eq ['default_privacy']
    expect(upsert_all['violations']).to eq []
    expect(upsert_all['unlisted_reviews'].size).to eq 1
    expect(details(multiline, 'violations')).to eq ['default_privacy']
    expect(dynamic_setter['unlisted_reviews'].map(&:kind)).to eq ['dynamic_setter']
    expect(details(sql, 'violations')).to eq ['default_privacy']
    expect(other['violations']).to eq []
    expect(other['reviews']).to eq []
    described_class::ALLOW.each do |entry|
      expect(entry[:path]).not_to start_with('app/services/example_')
    end
  end

  it 'rejects a new nine-key literal inside an allowlisted file' do
    source = Rails.root.join('app/lib/user_preferences/writer.rb').read
    source += "\ndef extra_nine_key\n  user.settings['default_privacy'] = 'direct'\nend\n"
    result = audit.scan_content('app/lib/user_preferences/writer.rb', source)

    expect(result['violations'].map(&:detail)).to include('default_privacy')
    expect(result['allowed_reviews'].map(&:defn)).not_to include('extra_nine_key')
  end

  it 'rejects a new dynamic write inside an allowlisted file' do
    source = Rails.root.join('app/lib/user_preferences/writer.rb').read
    source += "\ndef extra_dynamic\n  user.settings[key] = value\nend\n"
    result = audit.scan_content('app/lib/user_preferences/writer.rb', source)

    expect(result['unlisted_reviews'].map(&:defn)).to include('extra_dynamic')
    expect(result['allowed_reviews'].map(&:defn)).to include('insert_row', 'update_row', 'delete_row')
  end
end
