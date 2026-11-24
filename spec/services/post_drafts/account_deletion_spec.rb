# frozen_string_literal: true

require 'rails_helper'

describe 'post drafts during account deletion' do
  def payload(text, media_id, sender_id = nil)
    input = {
      'text' => text,
      'privacy' => 'personal',
      'media' => [{
        'id' => media_id.to_s,
        'order' => 0,
        'description' => "draft\nalt",
        'focus' => { 'x' => -0.25, 'y' => 0.5 },
      }],
    }
    input['sender'] = { 'id' => sender_id, 'selection_origin' => 'explicit' } if sender_id
    { 'schema_version' => 1, 'input' => input }
  end

  def save_draft!(user, media, text, uuid:, sender_id: nil)
    result = PostDrafts::Store.new(user.account).create(
      client_uuid: uuid,
      payload: payload(text, media.id, sender_id)
    )
    expect(result.status).to eq :created
    result.draft
  end

  def grant!(grantor, grantee)
    PostingIdentityDelegation.create!(
      grantor_user: grantor,
      grantee_user: grantee,
      posting_account: grantor.account,
      scopes: %w(post media),
      expires_at: 30.days.from_now,
      approved_at: Time.current
    )
  end

  def record_audit!(media, grantor, grantee, delegation)
    PostingIdentity::MediaAudit.record!(
      media: media,
      grantee_user_id: grantee.id,
      delegation_id: delegation.id,
      posting_account_id: grantor.account.id
    )
  end

  describe 'AccountDeletionWorker defaults' do
    it 'keeps the username, deletes the user, the private draft, the join, and the unretained file' do
      user = Fabricate(:user, confirmed_at: Time.zone.now, approved: true)
      account = user.account
      secret = "private draft\nkeep this off the reserved account"
      media = Fabricate(:media_attachment, account: account)
      path = media.file.path
      draft = save_draft!(user, media, secret, uuid: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1')
      username = account.username

      expect(user).to be_confirmed
      expect(user).to be_approved
      expect(account.user_unconfirmed_or_pending?).to be false
      expect(File.exist?(path)).to be true

      AccountDeletionWorker.new.perform(account.id)

      expect(Account.find(account.id).username).to eq username
      expect(account.reload).to be_suspended
      expect(User.exists?(user.id)).to be false
      expect(PostDraft.exists?(draft.id)).to be false
      expect(PostDraft.where(account_id: account.id)).to be_empty
      expect(PostDraft.where("payload #>> '{input,text}' = ?", secret)).to be_empty
      expect(PostDraftMediaAttachment.where(post_draft_id: draft.id)).to be_empty
      expect(MediaAttachment.exists?(media.id)).to be false
      expect(File.exist?(path)).to be false

      expect { AccountDeletionWorker.new.perform(account.id) }.not_to raise_error
      expect(Account.find(account.id).username).to eq username
      expect(PostDraft.where("payload #>> '{input,text}' = ?", secret)).to be_empty
    end

    it 'keeps an unresolved report target and still blocks cleanup of a live draft' do
      user = Fabricate(:user, confirmed_at: Time.zone.now, approved: true)
      reporter = Fabricate(:user)
      reported = Fabricate(:status, account: user.account, visibility: :private, text: 'reported post')
      reported_media = Fabricate(:media_attachment, account: user.account, status: reported)
      reported_path = reported_media.file.path
      Fabricate(:report, account: reporter.account, target_account: user.account, status_ids: [reported.id], action_taken_at: nil)
      ordinary = Fabricate(:status, account: user.account, visibility: :private, text: 'ordinary post')
      ordinary_media = Fabricate(:media_attachment, account: user.account, status: ordinary)

      keeper = Fabricate(:user, confirmed_at: Time.zone.now, approved: true)
      kept = Fabricate(:media_attachment, account: keeper.account, created_at: 10.days.ago)
      kept_path = kept.file.path
      kept_draft = save_draft!(keeper, kept, 'still drafting', uuid: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2')
      stale = Fabricate(:media_attachment, account: keeper.account, created_at: 10.days.ago)

      AccountDeletionWorker.new.perform(user.account_id)

      expect(Status.exists?(reported.id)).to be true
      expect(MediaAttachment.exists?(reported_media.id)).to be true
      expect(reported_media.reload.status_id).to eq reported.id
      expect(File.exist?(reported_path)).to be true
      expect(Status.exists?(ordinary.id)).to be false
      expect(MediaAttachment.exists?(ordinary_media.id)).to be false

      expect(PostDraft.exists?(kept_draft.id)).to be true
      expect(kept_draft.reload.payload.dig('input', 'text')).to eq 'still drafting'
      expect(kept.destroy).to eq false
      expect(MediaAttachment.exists?(kept.id)).to be true
      expect(File.exist?(kept_path)).to be true
      expect(PostDraftMediaAttachment.exists?(media_attachment_id: kept.id)).to be true

      Scheduler::MediaCleanupScheduler.new.perform

      expect(MediaAttachment.exists?(kept.id)).to be true
      expect(File.exist?(kept_path)).to be true
      expect { stale.reload }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe 'other deletion and suspension paths' do
    let(:grantor) { user_with_role('Owner') }
    let(:grantee) { user_with_role('Owner') }

    it 'removes the account row without taking another account draft that names its file' do
      delegation = grant!(grantor, grantee)
      own_media = Fabricate(:media_attachment, account: grantor.account)
      own_path = own_media.file.path
      own_draft = save_draft!(grantor, own_media, "grantor private\nbody", uuid: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1')
      shared = Fabricate(:media_attachment, account: grantor.account)
      shared_path = shared.file.path
      record_audit!(shared, grantor, grantee, delegation)
      other_draft = save_draft!(
        grantee,
        shared,
        'grantee private note',
        uuid: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2',
        sender_id: "delegated:#{grantor.account.id}"
      )

      DeleteAccountService.new.call(grantor.account, reserve_username: false, reserve_email: false, skip_side_effects: true)

      expect(Account.exists?(grantor.account_id)).to be false
      expect(User.exists?(grantor.id)).to be false
      expect(PostDraft.exists?(own_draft.id)).to be false
      expect(PostDraft.where("payload #>> '{input,text}' = ?", "grantor private\nbody")).to be_empty
      expect(MediaAttachment.exists?(own_media.id)).to be false
      expect(File.exist?(own_path)).to be false

      expect(PostDraft.exists?(other_draft.id)).to be true
      expect(other_draft.reload.payload.dig('input', 'text')).to eq 'grantee private note'
      expect(other_draft.account_id).to eq grantee.account_id
      expect(PostDraftMediaAttachment.exists?(post_draft_id: other_draft.id, media_attachment_id: shared.id)).to be true
      expect(MediaAttachment.exists?(shared.id)).to be true
      expect(shared.reload.account_id).to be_nil
      expect(File.exist?(shared_path)).to be true
      expect(User.exists?(grantee.id)).to be true

      shared.update_columns(created_at: 10.days.ago)
      restored = PostDrafts::Presenter.new(grantee).one(other_draft.reload)
      expect(restored[:media_retained]).to be true
      expect(restored[:media_restore]).to eq 'partial'
      expect(restored[:media]).to eq []

      Scheduler::MediaCleanupScheduler.new.perform
      expect(MediaAttachment.exists?(shared.id)).to be true
      expect(File.exist?(shared_path)).to be true

      removed = PostDrafts::Store.new(grantee.account).destroy(other_draft.id, expected_revision: other_draft.revision)
      expect(removed.status).to eq :deleted
      expect(PostDraftMediaAttachment.exists?(media_attachment_id: shared.id)).to be false
      expect(File.exist?(shared_path)).to be true

      Scheduler::MediaCleanupScheduler.new.perform
      expect(MediaAttachment.exists?(shared.id)).to be false
      expect(File.exist?(shared_path)).to be false
    end

    it 'drops the operator draft and leaves the grantor draft when the operator account is reserved' do
      delegation = grant!(grantor, grantee)
      grantor_media = Fabricate(:media_attachment, account: grantor.account)
      grantor_draft = save_draft!(grantor, grantor_media, 'grantor still here', uuid: 'cccccccc-cccc-4ccc-8ccc-ccccccccccc1')
      delegated_media = Fabricate(:media_attachment, account: grantor.account)
      delegated_path = delegated_media.file.path
      record_audit!(delegated_media, grantor, grantee, delegation)
      operator_draft = save_draft!(
        grantee,
        delegated_media,
        'operator private',
        uuid: 'cccccccc-cccc-4ccc-8ccc-ccccccccccc2',
        sender_id: "delegated:#{grantor.account.id}"
      )

      AccountDeletionWorker.new.perform(grantee.account_id)

      expect(Account.exists?(grantee.account_id)).to be true
      expect(User.exists?(grantee.id)).to be false
      expect(PostDraft.exists?(operator_draft.id)).to be false
      expect(PostDraft.where("payload #>> '{input,text}' = ?", 'operator private')).to be_empty
      expect(PostDraft.exists?(grantor_draft.id)).to be true
      expect(grantor_draft.reload.payload.dig('input', 'text')).to eq 'grantor still here'
      expect(MediaAttachment.exists?(grantor_media.id)).to be true
      expect(MediaAttachment.exists?(delegated_media.id)).to be true
      expect(delegated_media.reload.account_id).to eq grantor.account.id
      expect(File.exist?(delegated_path)).to be true
      expect(PostDraftMediaAttachment.exists?(post_draft_id: grantor_draft.id)).to be true
      expect(PostDraftMediaAttachment.exists?(post_draft_id: operator_draft.id)).to be false
    end

    it 'leaves the draft, the join, and the file in place when the account is only suspended' do
      user = Fabricate(:user, confirmed_at: Time.zone.now, approved: true)
      media = Fabricate(:media_attachment, account: user.account)
      path = media.file.path
      draft = save_draft!(user, media, "suspended\nstill private", uuid: 'dddddddd-dddd-4ddd-8ddd-ddddddddddd1')

      SuspendAccountService.new.call(user.account)

      expect(user.account.reload).to be_suspended
      expect(User.exists?(user.id)).to be true
      expect(PostDraft.exists?(draft.id)).to be true
      expect(draft.reload.payload.dig('input', 'text')).to eq "suspended\nstill private"
      expect(PostDraftMediaAttachment.exists?(post_draft_id: draft.id, media_attachment_id: media.id)).to be true
      expect(MediaAttachment.exists?(media.id)).to be true
      expect(File.exist?(path)).to be true
    end
  end
end
