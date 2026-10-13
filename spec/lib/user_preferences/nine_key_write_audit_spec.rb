# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('script/settings_service_catalog/nine_key_write_audit')

RSpec.describe SettingsServiceCatalog::NineKeyWriteAudit do
  subject(:audit) { described_class.new(Rails.root) }

  it 'accepts the repository and lists only allowlisted dynamic writes' do
    result = audit.call

    expect(result['violations']).to eq []
    expect(result['ok']).to be true
    expect(result['scanned_files']).to be > 1000
    expect(result['reviews'].map(&:path).uniq - described_class::ALLOW.keys).to eq []
    expect(result['reviews'].map(&:path)).to include(
      'app/lib/user_settings_decorator.rb',
      'app/lib/user_preferences/writer.rb',
      'app/lib/settings/scoped_settings.rb'
    )
  end

  it 'detects a literal nine-key assignment in a fixture' do
    result = audit.scan_content(
      'app/services/example_preference_write.rb',
      "user.settings['default_privacy'] = 'direct'\n"
    )

    expect(result['violations'].map(&:detail)).to eq ['default_privacy']
    expect(result['reviews']).to eq []
  end

  it 'reports an unlisted dynamic write instead of treating it as clean' do
    result = audit.scan_content(
      'app/services/example_dynamic_write.rb',
      "user.settings[key] = value\n"
    )

    expect(result['violations']).to eq []
    expect(result['reviews'].map(&:kind)).to eq ['dynamic_write']
    expect(described_class::ALLOW).not_to have_key('app/services/example_dynamic_write.rb')
  end

  it 'does not flag a read or a different setting' do
    result = audit.scan_content(
      'app/services/example_other_setting.rb',
      <<~RUBY
        user.settings['disable_post'] = true
        value = user.settings['default_privacy']
        Setting.unscoped.where(thing_type: 'User', var: 'default_privacy')
      RUBY
    )

    expect(result['violations']).to eq []
    expect(result['reviews']).to eq []
  end
end
