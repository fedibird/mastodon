# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GroupCreationIcons::Copy do
  before { load Rails.root.join('db', 'seeds', '03_roles.rb') }

  around do |example|
    previous = Setting.group_creation_requests
    Setting.group_creation_requests = true
    Dir.mktmpdir do |dir|
      ClimateControl.modify(GROUP_CREATION_ICON_ROOT: dir, GROUP_CREATION_ICON_STORAGE: 'filesystem', S3_ENABLED: nil, SWIFT_ENABLED: nil) do
        example.run
      end
    end
  ensure
    Setting.group_creation_requests = previous
  end

  let(:requester) { Fabricate(:user) }
  let(:reviewer) { user_with_role('Owner') }
  let(:png) { File.binread(Rails.root.join('spec/fixtures/files/emojo.png')) }

  def stage(bytes, mime: 'image/png', username: 'icongroup')
    key = GroupCreationIcons.generate_key
    GroupCreationIcons::Storage.resolve.write(key, StringIO.new(bytes), content_type: mime)
    GroupCreationRequest.create!(
      requester_account: requester.account,
      username: username,
      display_name: 'Icon Group',
      note: 'icon',
      icon_storage_key: key,
      icon_content_type: mime,
      icon_byte_size: bytes.bytesize
    )
  end

  def approve(request)
    GroupCreationRequests::ApproveService.call(request: request, reviewer_account: reviewer.account)
  end

  it 'copies a real icon after approval and deletes the private original' do
    reviewer
    request = stage(png)
    result = nil
    expect(GroupCreationIcons::HandoffWorker).to receive(:perform_async).and_call_original

    expect { result = approve(request) }.to change(Account, :count).by(1)

    expect(result.code).to eq :approved
    group = result.group_account.reload
    request.reload
    expect(group.avatar_file_name).to be_present
    expect(group.avatar_remote_url).to be_blank
    expect(File.exist?(group.avatar.path)).to be true
    expect(request.icon_handoff_copied_at).to be_present
    expect(request.icon_handoff_source_digest).to eq Digest::SHA256.hexdigest(png)
    expect(request.icon_purged_at).to be_present
    expect(GroupCreationIcons::Storage.resolve.exist?(request.icon_storage_key)).to be false
    expect(group.user).to be_nil
  end

  it 'refuses a missing, corrupt, or unreadable icon without creating a group' do
    missing = stage(png, username: 'missingicon')
    GroupCreationIcons::Storage.resolve.delete(missing.icon_storage_key)
    expect(approve(missing).code).to eq :icon_missing
    expect(missing.reload).to be_pending
    expect(Account.where(username: 'missingicon')).to be_empty

    corrupt = stage('not-an-image', username: 'corrupticon')
    expect(approve(corrupt).code).to eq :invalid_icon
    expect(corrupt.reload).to be_pending

    blocked = stage(png, username: 'blockedicon')
    allow(GroupCreationIcons::Storage).to receive(:resolve).and_raise(GroupCreationIcons::ConfigurationError)
    expect(approve(blocked).code).to eq :storage_unavailable
    expect(blocked.reload).to be_pending
    expect(Account.where(username: %w(missingicon corrupticon blockedicon))).to be_empty
  end

  it 'keeps the private original when the avatar copy fails and retries it' do
    request = stage(png, username: 'retryicon')
    allow(GroupCreationIcons::HandoffWorker).to receive(:perform_async)
    result = approve(request)
    expect(result.code).to eq :approved
    group = result.group_account
    expect(group.avatar_file_name).to be_blank
    expect(GroupCreationIcons::Storage.resolve.exist?(request.icon_storage_key)).to be true

    allow(group).to receive(:save!).and_raise(IOError, 'disk')
    allow(Account).to receive(:find).and_call_original
    allow_any_instance_of(GroupCreationRequest).to receive(:group_account).and_return(group)

    expect { described_class.call(request.reload) }.to raise_error(IOError)
    expect(request.reload.icon_handoff_copied_at).to be_nil
    expect(request.icon_handoff_error).to eq 'copy_failed'
    expect(request.icon_handoff_attempts).to eq 1
    expect(GroupCreationIcons::Storage.resolve.exist?(request.icon_storage_key)).to be true
    expect(Account.where(username: 'retryicon').count).to eq 1

    allow_any_instance_of(GroupCreationRequest).to receive(:group_account).and_call_original
    described_class.call(request.reload)
    expect(request.reload.icon_handoff_copied_at).to be_present
    expect(request.icon_purged_at).to be_present
    expect(Account.where(username: 'retryicon').count).to eq 1
  end

  it 'retries deletion of the private original without copying the avatar again' do
    request = stage(png, username: 'releaseicon')
    allow(GroupCreationIcons::HandoffWorker).to receive(:perform_async)
    group = approve(request).group_account
    storage = GroupCreationIcons::Storage.resolve
    allow(GroupCreationIcons::Storage).to receive(:resolve).and_return(storage)
    allow(storage).to receive(:delete).and_raise(IOError, 'delete failed')

    expect { described_class.call(request.reload) }.to raise_error(GroupCreationIcons::Copy::Error)
    request.reload
    group.reload
    expect(request.icon_handoff_copied_at).to be_present
    expect(request.icon_purged_at).to be_nil
    expect(storage.exist?(request.icon_storage_key)).to be true
    copied_name = group.avatar_file_name
    copied_at = group.avatar_updated_at

    allow(storage).to receive(:delete).and_call_original
    expect { described_class.call(request) }.not_to change(Account, :count)
    expect(request.reload.icon_purged_at).to be_present
    expect(group.reload.avatar_file_name).to eq copied_name
    expect(group.avatar_updated_at).to eq copied_at
    expect(GroupRoleAssignment.where(group_account: group).count).to eq 1
  end

  it 'does not write the avatar twice when two copies run' do
    request = stage(png, username: 'twiceicon')
    allow(GroupCreationIcons::HandoffWorker).to receive(:perform_async)
    group = approve(request).group_account
    described_class.call(request.reload)
    updated_at = group.reload.avatar_updated_at

    described_class.call(request.reload)
    expect(group.reload.avatar_updated_at).to eq updated_at
    expect(request.reload.icon_purged_at).to be_present
    expect(Account.where(username: 'twiceicon').count).to eq 1
  end
end
