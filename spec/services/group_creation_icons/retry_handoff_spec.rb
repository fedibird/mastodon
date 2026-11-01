# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GroupCreationIcons::RetryHandoff do
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

  let(:reviewer) { user_with_role('Owner') }
  let(:png) { File.binread(Rails.root.join('spec/fixtures/files/emojo.png')) }

  def stage(username)
    key = GroupCreationIcons.generate_key
    GroupCreationIcons::Storage.resolve.write(key, StringIO.new(png), content_type: 'image/png')
    GroupCreationRequest.create!(
      requester_account: Fabricate(:user).account,
      username: username,
      display_name: 'Retry',
      note: 'retry',
      icon_storage_key: key,
      icon_content_type: 'image/png',
      icon_byte_size: png.bytesize
    )
  end

  def approve(request)
    allow(GroupCreationIcons::HandoffWorker).to receive(:perform_async)
    GroupCreationRequests::ApproveService.call(request: request, reviewer_account: reviewer.account)
    request.reload
  end

  it 'does not resume a pending request or accept a moderator' do
    request = GroupCreationRequest.create!(
      requester_account: Fabricate(:user).account,
      username: 'retryonly',
      display_name: 'Retry',
      note: 'retry'
    )

    expect(described_class.call(request: request, actor_account: reviewer.account)).to eq :not_retryable
    expect(described_class.call(request: request, actor_account: user_with_role('Moderator').account)).to eq :not_authorized
    expect(request.reload).to be_pending
  end

  it 'resets an exhausted copy once and leaves it in the hourly recovery scope if enqueue fails' do
    request = approve(stage('exhaustedicon'))
    request.update!(icon_handoff_attempts: GroupCreationIcons::Copy::MAX_ATTEMPTS, icon_handoff_error: 'copy_failed', icon_handoff_failed_at: Time.current)
    expect(GroupCreationIcons::HandoffRecovery.exhausted_scope.where(id: request.id)).to exist

    allow(GroupCreationIcons::HandoffWorker).to receive(:perform_async).and_raise(StandardError.new('redis down'))
    expect(described_class.call(request: request, actor_account: reviewer.account)).to eq :enqueue_failed

    request.reload
    expect(request.icon_handoff_attempts).to eq 0
    expect(request.icon_handoff_error).to be_nil
    expect(request.icon_handoff_copied_at).to be_nil
    expect(GroupCreationIcons::HandoffRecovery.scope.where(id: request.id)).to exist
    expect(GroupCreationIcons::HandoffRecovery.exhausted_scope.where(id: request.id)).not_to exist
  end

  it 'enqueues a second retry without resetting the resumed copy again' do
    request = approve(stage('secondretry'))
    request.update!(icon_handoff_attempts: GroupCreationIcons::Copy::MAX_ATTEMPTS, icon_handoff_error: 'copy_failed', icon_handoff_failed_at: Time.current)
    expect(GroupCreationIcons::HandoffWorker).to receive(:perform_async).with(request.id).twice.and_return('jid')

    expect(described_class.call(request: request, actor_account: reviewer.account)).to eq :resumed
    expect(described_class.call(request: request.reload, actor_account: reviewer.account)).to eq :enqueued
    expect(request.reload.icon_handoff_attempts).to eq 0
  end

  it 'enqueues cleanup again when the avatar was copied and the private original remains' do
    request = approve(stage('copiedicon'))
    request.update!(
      icon_handoff_copied_at: Time.current,
      icon_handoff_source_digest: Digest::SHA256.hexdigest(png),
      icon_handoff_attempts: 1
    )
    expect(GroupCreationIcons::HandoffWorker).to receive(:perform_async).with(request.id).and_return('jid')

    expect(described_class.call(request: request, actor_account: reviewer.account)).to eq :enqueued
    expect(request.reload.icon_handoff_copied_at).to be_present
    expect(request.icon_purged_at).to be_nil
    expect(GroupCreationIcons::HandoffRecovery.scope.where(id: request.id)).to exist
  end
end
