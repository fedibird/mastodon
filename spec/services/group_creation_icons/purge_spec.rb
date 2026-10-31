# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GroupCreationIcons::Purge do
  include ExternalBridgeIconHelpers

  before { load Rails.root.join('db', 'seeds', '03_roles.rb') }

  around do |example|
    Dir.mktmpdir do |dir|
      ClimateControl.modify(GROUP_CREATION_ICON_ROOT: dir, GROUP_CREATION_ICON_STORAGE: 'filesystem', S3_ENABLED: nil, SWIFT_ENABLED: nil) do
        example.run
      end
    end
  end

  let(:requester) { Fabricate(:user) }
  let(:reviewer) { user_with_role('Owner') }

  def store_request(username: 'iconreq')
    bytes = icon_image('png')
    key = GroupCreationIcons.generate_key
    GroupCreationIcons::Storage.resolve.write(key, StringIO.new(bytes), content_type: 'image/png')
    request = GroupCreationRequest.create!(
      requester_account: requester.account,
      username: username,
      display_name: 'Icon Group',
      note: 'with an icon',
      icon_storage_key: key,
      icon_content_type: 'image/png',
      icon_byte_size: bytes.bytesize,
      submission_token: SecureRandom.uuid
    )
    [request, key, bytes]
  end

  it 'deletes the icon after cancellation commits and can retry a failed delete' do
    request, key, = store_request
    storage = GroupCreationIcons::Storage.resolve
    allow(GroupCreationIcons::Storage).to receive(:resolve).and_return(storage)
    allow(storage).to receive(:delete).and_raise(GroupCreationIcons::Error, 'disk')

    request.record_cancellation!

    expect(request.reload).to be_cancelled
    expect(request.icon_purged_at).to be_nil
    expect(storage.exist?(key)).to be true

    allow(storage).to receive(:delete).and_call_original
    described_class.call(request)

    expect(request.reload.icon_purged_at).to be_present
    expect(storage.exist?(key)).to be false
    expect(request.icon_storage_key).to eq key
  end

  it 'keeps going when one terminal icon raises a storage exception' do
    first, = store_request(username: 'purgeone')
    second, second_key, = store_request(username: 'purgetwo')
    first.record_cancellation!
    second.record_cancellation!
    first.update_columns(icon_purged_at: nil)
    second.update_columns(icon_purged_at: nil)
    storage = GroupCreationIcons::Storage.resolve
    allow(GroupCreationIcons::Storage).to receive(:resolve).and_return(storage)
    allow(storage).to receive(:delete).and_wrap_original do |method, key|
      raise RuntimeError, 'sdk timeout' if key == first.icon_storage_key

      method.call(key)
    end

    counts = described_class.purge_terminal

    expect(counts[:failed]).to eq 1
    expect(counts[:purged]).to be >= 1
    expect(first.reload.icon_purged_at).to be_nil
    expect(second.reload.icon_purged_at).to be_present
    expect(storage.exist?(second_key)).to be false
  end

  it 'deletes the icon after rejection and keeps it across approval until P2 releases it' do
    rejected, rejected_key, = store_request(username: 'rejecticon')
    rejected.record_rejection!(reviewer_account: reviewer.account, decision_note: 'not a fit')
    expect(rejected.reload.icon_purged_at).to be_present
    expect(GroupCreationIcons::Storage.resolve.exist?(rejected_key)).to be false

    request, key, bytes = store_request(username: 'approveicon')
    group = nil
    GroupCreationRequest.transaction do
      group = Fabricate(:account, username: request.username, display_name: request.display_name, note: request.note, actor_type: 'Group')
      ManagedGroup.create!(account: group, origin: :approved_request, creation_request: request)
      GroupRoleAssignment.create!(
        group_account: group,
        member_account: requester.account,
        role: :owner,
        granted_by_account: reviewer.account,
        granted_at: Time.current
      )
      request.record_approval!(reviewer_account: reviewer.account, group_account: group)
    end

    expect(request.reload).to be_approved
    expect(request.icon_purged_at).to be_nil
    expect(GroupCreationIcons::Storage.resolve.read(key)).to eq bytes
    expect(group.reload.avatar_file_name).to be_nil
    expect(group.avatar_remote_url).to be_nil

    file = GroupCreationIcons::Handoff.staged_original(request)
    expect(file.read).to eq bytes
    file.close!

    pending_request, = store_request(username: 'stillpending')
    expect { GroupCreationIcons::Handoff.release_after_copy!(pending_request) }.to raise_error(GroupCreationIcons::Error)
    GroupCreationIcons::Handoff.release_after_copy!(request)
    expect(request.reload.icon_purged_at).to be_present
    expect(GroupCreationIcons::Storage.resolve.exist?(key)).to be false
  end
end
