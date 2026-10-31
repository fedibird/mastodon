# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GroupCreationRequest do # rubocop:disable Metrics/BlockLength
  before { load Rails.root.join('db', 'seeds', '03_roles.rb') }

  let(:requester) { Fabricate(:user) }
  let(:reviewer) { user_with_role('Owner') }

  def submit_request(**attrs)
    described_class.create!(
      {
        requester_account: requester.account,
        username: 'freshgroup',
        display_name: 'Fresh Group',
        note: 'A local group',
      }.merge(attrs)
    )
  end

  def approve!(request, owner_account: request.requester_account, reviewer_account: reviewer.account)
    group = nil
    described_class.transaction do
      group = Fabricate(:account, username: request.username, display_name: request.display_name, note: request.note, actor_type: 'Group')
      ManagedGroup.create!(account: group, origin: :approved_request, creation_request: request)
      GroupRoleAssignment.create!(
        group_account: group,
        member_account: owner_account,
        role: :owner,
        granted_by_account: reviewer_account,
        granted_at: Time.current
      )
      request.record_approval!(reviewer_account: reviewer_account, group_account: group)
    end
    group
  end

  it 'stores a pending snapshot without creating a group account or a role' do
    requester
    request = nil

    expect do
      request = submit_request(username: 'NewGroup')
    end.not_to(change { [Account.count, User.count, ManagedGroup.count, GroupRoleAssignment.count, GroupAffiliation.count, Follow.count] })

    expect(request).to be_pending
    expect(request.username).to eq 'newgroup'
    expect(request.requested_at).to be_present
    expect(Account.where(username: 'newgroup')).to be_empty
    expect(ActionReview::OperationRegistry.registered?('group_creation')).to be false
    expect(ActionReview::OperationRegistry.keys).not_to include('group_creation_request')
  end

  it 'does not reserve a pending username' do
    request = submit_request
    other = Fabricate(:user)

    expect(request.username_available_for_approval?).to be true
    second = submit_request(requester_account: other.account, username: 'FRESHGROUP')
    expect(second.username).to eq request.username

    Fabricate(:account, username: 'freshgroup')
    expect(request.reload).to be_pending
    expect(request.username_available_for_approval?).to be false

    later = Fabricate(:user)
    expect { submit_request(requester_account: later.account) }.to raise_error(ActiveRecord::RecordInvalid) { |error|
      expect(error.record.errors.added?(:username, :taken)).to be true
    }
  end

  it 'rejects a username that a local account already uses, regardless of case' do
    Fabricate(:account, username: 'TakenName')
    record = described_class.new(requester_account: requester.account, username: 'takenname', display_name: 'X', note: '')

    expect(record).not_to be_valid
    expect(record.errors.added?(:username, :taken)).to be true
  end

  it 'rejects reserved, malformed, and overlong names and text' do
    reserved = described_class.new(requester_account: requester.account, username: 'Admin', display_name: '', note: '')
    expect(reserved).not_to be_valid
    expect(reserved.errors.added?(:username, :reserved)).to be true

    dotted = described_class.new(requester_account: requester.account, username: 'has.dot', display_name: '', note: '')
    expect(dotted).not_to be_valid

    long_name = described_class.new(requester_account: requester.account, username: 'a' * 31, display_name: '', note: '')
    expect(long_name).not_to be_valid

    long_display = described_class.new(requester_account: requester.account, username: 'okname', display_name: 'あ' * 31, note: '')
    expect(long_display).not_to be_valid
    expect(long_display.errors.added?(:display_name, :too_long, count: 30)).to be true

    long_note = described_class.new(requester_account: requester.account, username: 'oknote', display_name: '', note: 'a' * 501)
    expect(long_note).not_to be_valid
    expect(long_note.errors[:note]).to be_present
  end

  it 'rejects applicants that are not a local functional person' do
    remote = Fabricate(:account, domain: 'remote.example', username: 'remotealice')
    group = Fabricate(:account, username: 'alreadygroup', actor_type: 'Group')
    bot = Fabricate(:user, account: Fabricate(:account, username: 'servicebot', actor_type: 'Service'))
    suspended = Fabricate(:user)
    suspended.account.update_columns(suspended_at: Time.now.utc)

    [remote, group, bot.account, suspended.account].each do |account|
      record = described_class.new(requester_account: account, username: "name#{account.id}", display_name: '', note: '')
      expect(record).not_to be_valid
      expect(record.errors.added?(:requester_account, :invalid)).to be true
    end
  end

  it 'keeps the submitted snapshot unchanged' do
    request = submit_request

    expect(request.update(username: 'othename', display_name: 'Changed', note: 'Changed note')).to be false
    expect(request.errors.added?(:username, :immutable)).to be true
    expect(request.reload.username).to eq 'freshgroup'
    expect(request.display_name).to eq 'Fresh Group'
  end

  it 'links a reapplication only to the same person closed request' do
    rejected = submit_request(username: 'firsttry')
    rejected.record_rejection!(reviewer_account: reviewer.account, decision_note: 'not yet')
    again = submit_request(username: 'secondtry', previous_request: rejected)

    expect(again.previous_request).to eq rejected
    expect(rejected.reload.successor_request).to eq again

    pending = submit_request(username: 'stillopen', requester_account: Fabricate(:user).account)
    reused = described_class.new(requester_account: requester.account, username: 'thirdtry', display_name: '', note: '', previous_request: pending)
    expect(reused).not_to be_valid

    other = described_class.new(requester_account: Fabricate(:user).account, username: 'fourthtry', display_name: '', note: '', previous_request: rejected)
    expect(other).not_to be_valid
  end

  it 'records approval only inside an already consistent group and does not create another account' do
    request = submit_request
    reviewer_account = reviewer.account
    expect { request.record_approval!(reviewer_account: reviewer_account, group_account: nil) }.to raise_error(ActiveRecord::RecordInvalid)
    expect(request.reload).to be_pending

    group = nil
    expect do
      group = approve!(request, reviewer_account: reviewer_account)
    end.to change(Account, :count).by(1)

    expect(request.reload).to be_approved
    expect(request.group_account).to eq group
    expect(request.initial_owner_account).to eq requester.account
    expect(request.reviewer_account).to eq reviewer.account
    expect(group.managed_group.creation_request).to eq request
    expect(group.group_role_assignments.active.owner.map(&:member_account)).to eq [requester.account]

    expect { request.record_approval!(reviewer_account: reviewer_account, group_account: group) }.to raise_error(ActiveRecord::RecordInvalid)
    expect(request.reload).to be_approved
    expect(Account.where(username: request.username).count).to eq 1
  end

  it 'refuses approval when the active owner is not the requester' do
    request = submit_request
    reviewer_account = reviewer.account
    someone = Fabricate(:user)

    expect { approve!(request, owner_account: someone.account, reviewer_account: reviewer_account) }.to raise_error(ActiveRecord::RecordInvalid)
    expect(request.reload).to be_pending
    expect(request.initial_owner_account).to be_nil
    expect(Account.where(username: 'freshgroup')).to be_empty
  end

  it 'refuses approval after the requester can no longer act, and leaves the request pending' do
    request = submit_request
    reviewer_account = reviewer.account
    group = Fabricate(:account, username: request.username, display_name: request.display_name, note: request.note, actor_type: 'Group')
    ManagedGroup.create!(account: group, origin: :approved_request, creation_request: request)
    GroupRoleAssignment.create!(
      group_account: group,
      member_account: requester.account,
      role: :owner,
      granted_by_account: reviewer_account,
      granted_at: Time.current
    )
    requester.account.update_columns(suspended_at: Time.now.utc)

    expect { request.record_approval!(reviewer_account: reviewer_account, group_account: group) }.to raise_error(ActiveRecord::RecordInvalid)
    expect(request.reload).to be_pending
    expect(request.group_account).to be_nil
  end

  it 'lets an admin reject and refuses a moderator or a legacy admin flag' do
    request = submit_request
    admin = user_with_role('Admin')
    request.record_rejection!(reviewer_account: admin.account, decision_note: 'needs a clearer name')
    expect(request.reload).to be_rejected

    moderator = user_with_role('Moderator')
    open_request = submit_request(username: 'anothername')
    expect { open_request.record_rejection!(reviewer_account: moderator.account, decision_note: 'no') }.to raise_error(ActiveRecord::RecordInvalid)
    expect(open_request.errors.added?(:reviewer_account, :invalid)).to be true

    legacy = Fabricate(:user, admin: true)
    expect { open_request.record_rejection!(reviewer_account: legacy.account, decision_note: 'no') }.to raise_error(ActiveRecord::RecordInvalid)
    expect(open_request.reload).to be_pending
  end

  it 'cancels without a reviewer and can be replaced' do
    request = submit_request
    request.record_cancellation!(decision_note: 'changed my mind')

    expect(request.reload).to be_cancelled
    expect(request.reviewer_account).to be_nil
    expect(request.cancelled_at).to be_present
    expect(request.group_account).to be_nil
  end

  it 'rejects an approved row that skips the database shape' do
    request = submit_request

    expect do
      described_class.transaction(requires_new: true) do
        request.update_columns(state: described_class.states[:approved])
      end
    end.to raise_error(ActiveRecord::StatementInvalid)
  end

  it 'does not add a public route for the request' do
    paths = Rails.application.routes.routes.map { |route| route.path.spec.to_s }

    expect(paths.grep(/group_creation_request|managed_group|group_role_assignment/)).to be_empty
  end
end
