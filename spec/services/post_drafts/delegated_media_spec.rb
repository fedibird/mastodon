# frozen_string_literal: true

require 'rails_helper'

describe 'delegated draft media' do
  let(:grantee) { user_with_role('Owner') }
  let(:grantor) { user_with_role('Owner') }
  let(:store) { PostDrafts::Store.new(grantee.account) }
  let(:uuid) { '99999999-9999-4999-8999-999999999999' }

  def grant!
    PostingIdentityDelegation.create!(
      grantor_user: grantor,
      grantee_user: grantee,
      posting_account: grantor.account,
      scopes: %w(post media),
      expires_at: 30.days.from_now,
      approved_at: Time.current
    )
  end

  def payload(media_id, sender_id)
    {
      'schema_version' => 1,
      'input' => {
        'text' => 'delegated',
        'privacy' => 'public',
        'media' => [{ 'id' => media_id.to_s, 'description' => 'from the operator' }],
        'sender' => { 'id' => sender_id, 'selection_origin' => 'explicit' },
      },
    }
  end

  it 'retains a still image the grant allows and stops when the grant is revoked' do
    delegation = grant!
    media = Fabricate(:media_attachment, account: grantor.account, description: 'grantor alt')
    PostingIdentity::MediaAudit.record!(
      media: media,
      grantee_user_id: grantee.id,
      delegation_id: delegation.id,
      posting_account_id: grantor.account.id
    )

    created = store.create(client_uuid: uuid, payload: payload(media.id, "delegated:#{grantor.account.id}"))
    view = PostDrafts::Presenter.new(grantee).one(created.draft)

    expect(created.status).to eq :created
    expect(created.draft.account_id).to eq grantee.account_id
    expect(media.reload.account_id).to eq grantor.account.id
    expect(media.description).to eq 'grantor alt'
    expect(view[:media_restore]).to eq 'complete'
    expect(view[:media].map { |row| row[:id] || row['id'] }).to eq [media.id.to_s]

    delegation.revoke!
    revoked = PostDrafts::Presenter.new(grantee).one(created.draft.reload)
    blocked = store.update(created.draft.id, expected_revision: 1, payload: payload(media.id, "delegated:#{grantor.account.id}").deep_merge('input' => { 'text' => 'edited' }))

    expect(revoked[:media_retained]).to be true
    expect(revoked[:media_restore]).to eq 'partial'
    expect(revoked[:media]).to eq []
    expect(blocked.status).to eq :invalid
    expect(blocked.error.errors.first['code']).to eq 'media_forbidden'
    expect(created.draft.reload.payload.dig('input', 'text')).to eq 'delegated'
    expect(PostDraftMediaAttachment.exists?(media_attachment_id: media.id)).to be true
    expect(media.reload.description).to eq 'grantor alt'
  end

  it 'does not accept the operator own file or the grantor file without an audit' do
    grant!
    own = Fabricate(:media_attachment, account: grantee.account)
    unaudited = Fabricate(:media_attachment, account: grantor.account)

    own_result = store.create(client_uuid: uuid, payload: payload(own.id, "delegated:#{grantor.account.id}"))
    missing_audit = store.create(client_uuid: '99999999-9999-4999-8999-999999999998', payload: payload(unaudited.id, "delegated:#{grantor.account.id}"))
    spoofed_sender = PostDrafts::Store.new(grantee.account).create(
      client_uuid: '99999999-9999-4999-8999-999999999997',
      payload: payload(unaudited.id, "local:#{grantee.account.id}")
    )

    expect(own_result.error.errors.first['code']).to eq 'media_forbidden'
    expect(missing_audit.error.errors.first['code']).to eq 'media_forbidden'
    expect(spoofed_sender.error.errors.first['code']).to eq 'media_forbidden'
    expect(PostDraft.where(account_id: grantee.account_id)).to be_empty
  end
end
