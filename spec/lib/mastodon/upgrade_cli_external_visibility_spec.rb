# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/mastodon/upgrade_cli')

RSpec.describe Mastodon::UpgradeCLI do
  def invoke(options = {})
    stdout = $stdout
    output = StringIO.new
    $stdout = output
    described_class.new.invoke(:external_status_visibility, [], options)
    output.string
  ensure
    $stdout = stdout
  end

  it 'keeps storage-schema dry-run default false and this command dry-run unless apply is set' do
    storage = described_class.commands['storage_schema']
    visibility = described_class.commands['external_status_visibility']
    expect(storage.options[:dry_run].default).to eq false
    expect(visibility.options[:apply].default).to eq false
  end

  it 'rejects an empty user id instead of scanning every projection' do
    expect { invoke(user_id: '') }.to raise_error(SystemExit) do |error|
      expect(error.status).to eq 1
    end
  end
end
