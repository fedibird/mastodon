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

  it 'does not mark the copy done or delete the original when the public file is missing' do
    request = stage(png, username: 'ghosticon')
    allow(GroupCreationIcons::HandoffWorker).to receive(:perform_async)
    group = approve(request).group_account
    group.update_columns(
      avatar_file_name: 'ghost.png',
      avatar_content_type: 'image/png',
      avatar_file_size: png.bytesize,
      avatar_updated_at: Time.current
    )
    request.update!(icon_handoff_source_digest: Digest::SHA256.hexdigest(png))
    allow_any_instance_of(described_class).to receive(:avatar_bytes_present?).and_return(false)

    expect { described_class.call(request.reload) }.not_to raise_error
    expect(request.reload.icon_handoff_copied_at).to be_nil
    expect(request.icon_purged_at).to be_nil
    expect(GroupCreationIcons::Storage.resolve.exist?(request.icon_storage_key)).to be true
    expect(Account.where(username: 'ghosticon').count).to eq 1
    expect(group.reload.avatar_remote_url).to be_blank
  end

  it 'keeps an approved group when enqueue fails and the scheduler finishes the icon' do
    reviewer
    request = stage(png, username: 'enqueueicon')
    allow(GroupCreationIcons::HandoffWorker).to receive(:perform_async).and_raise(IOError, 'redis down')

    result = nil
    expect { result = approve(request) }.to change(Account, :count).by(1)
    expect(result.code).to eq :approved
    expect(request.reload).to be_approved
    expect(request.icon_handoff_error).to eq 'enqueue_failed'
    expect(request.icon_handoff_copied_at).to be_nil
    expect(request.icon_purged_at).to be_nil
    expect(GroupRoleAssignment.active.owner.where(group_account: request.group_account).count).to eq 1
    expect(GroupCreationDecision.where(group_creation_request: request).count).to eq 1
    expect(approve(request).code).to eq :not_pending
    expect(Account.where(username: 'enqueueicon').count).to eq 1

    allow(GroupCreationIcons::HandoffWorker).to receive(:perform_async).and_call_original
    Scheduler::GroupCreationIconsScheduler.new.perform

    expect(request.reload.icon_handoff_copied_at).to be_present
    expect(request.icon_purged_at).to be_present
    expect(request.icon_handoff_error).to be_nil
    expect(request.group_account.reload.avatar.exists?).to be true
    expect(GroupCreationIcons::Storage.resolve.exist?(request.icon_storage_key)).to be false
    expect(Account.where(username: 'enqueueicon').count).to eq 1
  end

  it 'finishes the handoff after the reviewer, requester, and owner no longer match the approval' do
    request = stage(png, username: 'latericon')
    allow(GroupCreationIcons::HandoffWorker).to receive(:perform_async)
    result = approve(request)
    group = result.group_account
    successor = Fabricate(:user)
    GroupRoleAssignment.transfer_owner!(group_account: group, member_account: successor.account, granted_by_account: reviewer.account)
    reviewer.update_columns(role_id: nil)
    reviewer.update!(disabled: true)
    requester.update!(disabled: true)

    expect(GroupManagement.server_administrator?(reviewer.account)).to be false
    expect(GroupManagement.local_functional_person?(requester.account)).to be false
    expect(GroupRoleAssignment.active.owner.find_by!(group_account: group).member_account).to eq successor.account

    described_class.call(request.reload)
    expect(request.reload.icon_handoff_copied_at).to be_present
    expect(request.icon_purged_at).to be_present
    expect(request.initial_owner_account).to eq requester.account
    expect(group.reload.avatar.exists?).to be true
    expect(GroupCreationIcons::Storage.resolve.exist?(request.icon_storage_key)).to be false
    expect(Account.where(username: 'latericon').count).to eq 1
  end

  it 'stops after eight failures and resumes explicitly once storage works' do
    request = stage(png, username: 'exhausticon')
    allow(GroupCreationIcons::HandoffWorker).to receive(:perform_async)
    approve(request)
    failed = GroupCreationIcons::Revalidation::Result.new(code: :storage_unavailable)
    allow(GroupCreationIcons::Revalidation).to receive(:call).and_return(failed)

    GroupCreationIcons::Copy::MAX_ATTEMPTS.times do
      expect { described_class.call(request.reload) }.to raise_error(GroupCreationIcons::Copy::Error)
    end
    expect(request.reload.icon_handoff_attempts).to eq GroupCreationIcons::Copy::MAX_ATTEMPTS
    expect { described_class.call(request) }.not_to raise_error
    expect(request.reload.icon_handoff_attempts).to eq GroupCreationIcons::Copy::MAX_ATTEMPTS
    expect(GroupCreationIcons::HandoffRecovery.scope.where(id: request.id)).to be_empty
    expect(GroupCreationIcons::Storage.resolve.exist?(request.icon_storage_key)).to be true

    allow(GroupCreationIcons::Revalidation).to receive(:call).and_call_original
    expect { GroupCreationIcons::HandoffRecovery.call }.not_to change { request.reload.icon_handoff_copied_at }
    request.resume_icon_handoff!
    expect(request.icon_handoff_attempts).to eq 0
    GroupCreationIcons::HandoffRecovery.call

    expect(request.reload.icon_handoff_copied_at).to be_present
    expect(request.icon_purged_at).to be_present
    expect(request.group_account.avatar.exists?).to be true
    expect(GroupCreationIcons::Storage.resolve.exist?(request.icon_storage_key)).to be false
    expect(Account.where(username: 'exhausticon').count).to eq 1
  end
end
