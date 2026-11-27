# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PostDrafts::Feature do
  def administrator
    role = UserRole.create!(name: 'Draft sync root', permissions_as_keys: %w(administrator), position: 100)
    user = Fabricate(:user)
    user.update!(role: role)
    user
  end

  def moderator
    role = UserRole.create!(name: 'Draft sync mods', permissions_as_keys: %w(manage_reports), position: 10)
    user = Fabricate(:user)
    user.update!(role: role)
    user
  end

  it 'admits nobody while the flag is off' do
    user = Fabricate(:user)
    Setting.post_draft_sync = false
    Setting.post_draft_sync_testers = user.id.to_s

    expect(described_class.enabled?).to be false
    expect(described_class.permitted?(user)).to be false
    expect(described_class.permitted?(administrator)).to be false
  end

  it 'admits administrators and listed users, and not other staff' do
    listed = Fabricate(:user)
    outsider = Fabricate(:user)
    Setting.post_draft_sync = true
    Setting.post_draft_sync_testers = listed.id.to_s

    expect(described_class.permitted?(administrator)).to be true
    expect(described_class.permitted?(listed)).to be true
    expect(described_class.permitted?(outsider)).to be false
    expect(described_class.permitted?(moderator)).to be false
    expect(described_class.permitted?(nil)).to be false
  end

  it 'ignores blank and non-numeric tester ids' do
    Setting.post_draft_sync_testers = ' 12, no, 0, 34 '

    expect(described_class.tester_ids).to eq [12, 0, 34]
  end
end
