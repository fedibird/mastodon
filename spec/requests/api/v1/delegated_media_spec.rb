# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Delegated media uploads' do # rubocop:disable Metrics/BlockLength
  let(:grantee) { user_with_role('Owner', account: Fabricate(:account, username: 'poster')) }
  let(:grantor) { Fabricate(:user, account: Fabricate(:account, username: 'author')) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: grantee.id, scopes: 'write:media write:statuses') }
  let(:headers) { { 'Authorization' => "Bearer #{token.token}" } }
  let(:delegated_id) { "delegated:#{grantor.account.id}" }

  def delegate!(scopes: %w(post media), requester: grantee, owner: grantor)
    PostingIdentity::RequestAllowance.permit!(grantor: owner, acct: requester.account.username, scopes: scopes)
    issued = PostingIdentity::LinkRequestIssuer.call!(requester: requester, acct: owner.account.username, scopes: scopes, ip: '203.0.113.40')
    PostingIdentity::Approval.call!(approver: owner, token: issued.token)
  end

  def upload!(identity: delegated_id, name: 'attachment.jpg', content_type: 'image/jpeg', version: 'v2', extra: {})
    post "/api/#{version}/media", headers: headers, params: extra.merge(file: fixture_file_upload(name, content_type), posting_identity_id: identity)
  end

  def spoofed_file(source, filename, content_type)
    directory = Rails.root.join('tmp/delegated-media-spec')
    FileUtils.mkdir_p(directory)
    path = directory.join(filename)
    File.binwrite(path, Rails.root.join('spec/fixtures/files', source).binread)
    Rack::Test::UploadedFile.new(path, content_type, true, original_filename: filename)
  end

  describe 'POST /api/v2/media' do # rubocop:disable Metrics/BlockLength
    before do
      allow(PostProcessMediaWorker).to receive(:perform_async)
    end

    it 'stores a still image on the granting account and records the operator' do
      delegation = delegate!

      expect { upload! }.to change { grantor.account.media_attachments.count }.by(1)

      media = grantor.account.media_attachments.last
      audit = PostingIdentityMedia.find_by!(media_attachment_id: media.id)

      expect(response).to have_http_status(200)
      expect(media.account_id).to eq grantor.account.id
      expect(media.type).to eq 'image'
      expect(grantee.account.media_attachments).to be_empty
      expect(audit.grantee_user_id).to eq grantee.id
      expect(audit.delegation_id).to eq delegation.id
      expect(audit.posting_account_id).to eq grantor.account.id
      expect(audit.created_at).to be_present
      expect(PostingIdentityMedia.column_names).not_to include('description')
      expect(ActiveRecord::Base.connection.foreign_key_exists?(:posting_identity_media, :media_attachments)).to be false
    end

    it 'keeps the granting account upload on that account without an operator audit' do
      owner_token = Fabricate(:accessible_access_token, resource_owner_id: grantor.id, scopes: 'write:media')

      post '/api/v2/media', headers: { 'Authorization' => "Bearer #{owner_token.token}" }, params: {
        file: fixture_file_upload('attachment.jpg', 'image/jpeg'),
      }

      expect(response).to have_http_status(200)
      expect(grantor.account.media_attachments.last.account_id).to eq grantor.account.id
      expect(PostingIdentityMedia.count).to eq 0
    end

    it 'does not move the operator own upload onto the granting account' do
      delegate!

      post '/api/v2/media', headers: headers, params: { file: fixture_file_upload('attachment.jpg', 'image/jpeg') }

      expect(response).to have_http_status(200)
      expect(grantee.account.media_attachments.count).to eq 1
      expect(grantor.account.media_attachments).to be_empty
      expect(PostingIdentityMedia.count).to eq 0
    end

    it 'rejects post-only, media-only, revoked, expired, superseded, restricted, and suspended grants' do
      delegation = delegate!(scopes: %w(post))

      expect { upload! }.not_to change(MediaAttachment, :count)
      expect(response).to have_http_status(403)

      PostingIdentityDelegation.where(id: delegation.id).update_all(scopes: ['media'])

      expect { upload! }.not_to change(MediaAttachment, :count)
      expect(response).to have_http_status(403)

      PostingIdentityDelegation.where(id: delegation.id).update_all(scopes: %w(post media))
      PostingIdentity::Revocation.call!(actor: grantor, delegation: delegation.reload)

      expect { upload! }.not_to change(MediaAttachment, :count)
      expect(response).to have_http_status(403)

      delegation = delegate!
      delegation.update_columns(expires_at: 1.minute.ago)

      expect { upload! }.not_to change(MediaAttachment, :count)
      expect(response).to have_http_status(403)

      delegation.update_columns(expires_at: 30.days.from_now, superseded_at: Time.current)

      expect { upload! }.not_to change(MediaAttachment, :count)
      expect(response).to have_http_status(403)

      delegation.update_columns(superseded_at: nil)
      grantor.settings.disable_post = true

      expect { upload! }.not_to change(MediaAttachment, :count)
      expect(response).to have_http_status(403)

      grantor.settings.disable_post = false
      grantee.account.suspend!

      expect { upload! }.not_to change(MediaAttachment, :count)
      expect(response).to have_http_status(403)
    end

    it 'rejects a client account id, an external identity, and an ungranted account id' do
      delegate!
      stranger = Fabricate(:account, username: 'stranger')

      [
        { account_id: grantor.account.id, posting_identity_id: delegated_id },
        { posting_identity_id: 'mastodon:1' },
        { posting_identity_id: "delegated:#{stranger.id}" },
      ].each do |extra|
        expect { upload!(extra: extra.except(:posting_identity_id), identity: extra[:posting_identity_id]) }.not_to change(MediaAttachment, :count)
        expect(response).to have_http_status(403)
      end
    end

    it 'removes the upload when the audit row cannot be saved' do
      delegate!
      allow(PostingIdentity::MediaAudit).to receive(:record!).and_raise(ActiveRecord::RecordNotSaved, 'audit failed')

      expect { upload! }.to raise_error(ActiveRecord::RecordNotSaved)

      expect(grantor.account.media_attachments).to be_empty
      expect(PostingIdentityMedia.count).to eq 0
    end

    it 'rejects a video or audio file whose name claims to be a still image', :paperclip_processing do
      delegate!

      [
        ['attachment.webm', 'photo.jpg', 'image/jpeg'],
        ['boop.mp3', 'voice.png', 'image/png'],
        ['avatar.gif', 'motion.gif', 'image/gif'],
      ].each do |source, filename, content_type|
        expect do
          post '/api/v2/media', headers: headers, params: {
            file: spoofed_file(source, filename, content_type),
            posting_identity_id: delegated_id,
          }
        end.not_to(change { grantor.account.media_attachments.count })

        expect(response).to have_http_status(422)
        expect(PostingIdentityMedia.count).to eq 0
      end
    end
  end

  describe 'reading and updating an unattached image' do # rubocop:disable Metrics/BlockLength
    let!(:delegation) { delegate! }

    def uploaded_media
      upload!
      grantor.account.media_attachments.last
    end

    it 'returns processing state only for the operator upload' do
      media = uploaded_media
      media.update_columns(processing: MediaAttachment.processings[:queued])

      get "/api/v1/media/#{media.id}", headers: headers, params: { posting_identity_id: delegated_id }

      expect(response).to have_http_status(206)

      media.update_columns(processing: MediaAttachment.processings[:complete])

      get "/api/v1/media/#{media.id}", headers: headers, params: { posting_identity_id: delegated_id }

      expect(response).to have_http_status(200)
      expect(body_as_json[:id]).to eq media.id.to_s

      media.update_columns(processing: MediaAttachment.processings[:failed])

      get "/api/v1/media/#{media.id}", headers: headers, params: { posting_identity_id: delegated_id }

      expect(response).to have_http_status(422)
    end

    it 'does not treat a known url as permission to read another image' do
      media = uploaded_media
      own = Fabricate(:media_attachment, account: grantee.account, status: nil)
      owners = Fabricate(:media_attachment, account: grantor.account, status: nil)

      get "/api/v1/media/#{media.id}", headers: headers

      expect(response).to have_http_status(404)

      get "/api/v1/media/#{own.id}", headers: headers, params: { posting_identity_id: delegated_id }

      expect(response).to have_http_status(404)

      get "/api/v1/media/#{owners.id}", headers: headers, params: { posting_identity_id: delegated_id }

      expect(response).to have_http_status(404)
    end

    it 'updates the description and focus of the operator image only' do
      media = uploaded_media

      put "/api/v1/media/#{media.id}", headers: headers, params: {
        description: 'A hill',
        focus: '0.20,-0.40',
        posting_identity_id: delegated_id,
      }

      expect(response).to have_http_status(200)
      expect(media.reload.description).to eq 'A hill'
      expect(media.focus).to eq '0.2,-0.4'
      expect(PostingIdentityMedia.find_by!(media_attachment_id: media.id).delegation_id).to eq delegation.id
      expect(PostingIdentityMedia.column_names).not_to include('description')
    end

    it 'refuses updates after revocation and refuses attached or foreign images' do
      media = uploaded_media
      PostingIdentity::Revocation.call!(actor: grantor, delegation: delegation.reload)

      put "/api/v1/media/#{media.id}", headers: headers, params: {
        description: 'Changed',
        posting_identity_id: delegated_id,
      }

      expect(response).to have_http_status(403)
      expect(media.reload.description).not_to eq 'Changed'

      delegation.update_columns(revoked_at: nil)
      media.update_columns(status_id: Fabricate(:status, account: grantor.account).id)

      put "/api/v1/media/#{media.id}", headers: headers, params: {
        description: 'Attached',
        posting_identity_id: delegated_id,
      }

      expect(response).to have_http_status(404)
      expect(media.reload.description).not_to eq 'Attached'
    end
  end

  describe 'POST /api/v1/statuses' do # rubocop:disable Metrics/BlockLength
    before do
      allow(PostProcessMediaWorker).to receive(:perform_async)
    end

    it 'publishes the operator images on a status owned by the granting account' do
      delegation = delegate!
      upload!
      first = grantor.account.media_attachments.last
      put "/api/v1/media/#{first.id}", headers: headers, params: { description: 'Hill', posting_identity_id: delegated_id }
      upload!
      second = grantor.account.media_attachments.order(:id).last

      post '/api/v1/statuses', headers: headers.merge('Idempotency-Key' => 'media-once'), params: {
        status: 'Two hills',
        visibility: 'public',
        posting_identity_id: delegated_id,
        media_ids: [second.id, first.id, first.id],
      }

      status = grantor.account.statuses.last
      audit = PostingIdentityPost.find_by!(status_id: status.id)

      expect(response).to have_http_status(200)
      expect(status.account_id).to eq grantor.account.id
      expect(status.text).to eq 'Two hills'
      expect(status.ordered_media_attachments.map(&:id)).to eq [second.id, first.id]
      expect(status.media_attachments.map(&:account_id).uniq).to eq [grantor.account.id]
      expect(first.reload.status_id).to eq status.id
      expect(first.description).to eq 'Hill'
      expect(ActivityPub::TagManager.instance.uri_for(status)).to include("/users/#{grantor.account.username}/")
      expect(audit.grantee_user_id).to eq grantee.id
      expect(audit.delegation_id).to eq delegation.id
      expect(grantee.account.statuses).to be_empty

      expect do
        post '/api/v1/statuses', headers: headers.merge('Idempotency-Key' => 'media-once'), params: {
          status: 'Two hills',
          visibility: 'public',
          posting_identity_id: delegated_id,
          media_ids: [first.id, second.id],
        }
      end.not_to change(Status, :count)
    end

    it 'still publishes a text status with post alone' do
      delegate!(scopes: %w(post))

      post '/api/v1/statuses', headers: headers, params: {
        status: 'Words only',
        visibility: 'public',
        posting_identity_id: delegated_id,
      }

      expect(response).to have_http_status(200)
      expect(grantor.account.statuses.last.text).to eq 'Words only'
    end

    it 'rejects media the operator did not upload for this delegation' do
      delegate!
      upload!
      own = grantor.account.media_attachments.last
      owners = Fabricate(:media_attachment, account: grantor.account, status: nil)
      other_grantee = user_with_role('Owner', account: Fabricate(:account, username: 'other_poster'))
      other_delegation = delegate!(requester: other_grantee)
      other_media = Fabricate(:media_attachment, account: grantor.account, status: nil)
      PostingIdentityMedia.create!(
        grantee_user: other_grantee,
        delegation: other_delegation,
        posting_account: grantor.account,
        media_attachment_id: other_media.id
      )
      stranger = Fabricate(:media_attachment, account: grantee.account, status: nil)

      [owners.id, other_media.id, stranger.id, '999999', 'nope'].each do |media_id|
        expect do
          post '/api/v1/statuses', headers: headers, params: {
            status: 'Borrowed',
            visibility: 'public',
            posting_identity_id: delegated_id,
            media_ids: [media_id],
          }
        end.not_to change(Status, :count)

        expect(response).to have_http_status(403)
      end

      expect(owners.reload.status_id).to be_nil
      expect(other_media.reload.status_id).to be_nil
      expect(stranger.reload.account_id).to eq grantee.account.id
      expect(own.reload.status_id).to be_nil
    end

    it 'rejects an unfinished image, a reclassified video, and a media-only grant' do
      delegation = delegate!
      upload!
      media = grantor.account.media_attachments.last
      media.update_columns(processing: MediaAttachment.processings[:queued])

      expect do
        post '/api/v1/statuses', headers: headers, params: {
          status: 'Not ready',
          visibility: 'public',
          posting_identity_id: delegated_id,
          media_ids: [media.id],
        }
      end.not_to change(Status, :count)

      expect(response).to have_http_status(422)
      expect(media.reload.status_id).to be_nil

      media.update_columns(processing: MediaAttachment.processings[:complete], type: MediaAttachment.types[:video])

      expect do
        post '/api/v1/statuses', headers: headers, params: {
          status: 'Video',
          visibility: 'public',
          posting_identity_id: delegated_id,
          media_ids: [media.id],
        }
      end.not_to change(Status, :count)

      expect(response).to have_http_status(422)

      media.update_columns(type: MediaAttachment.types[:image])
      PostingIdentityDelegation.where(id: delegation.id).update_all(scopes: ['media'])

      expect do
        post '/api/v1/statuses', headers: headers, params: {
          status: 'Media only',
          visibility: 'public',
          posting_identity_id: delegated_id,
          media_ids: [media.id],
        }
      end.not_to change(Status, :count)

      expect(response).to have_http_status(403)
    end

    it 'refuses a new media post after revocation and leaves the image with the granting account' do
      delegation = delegate!
      upload!
      media = grantor.account.media_attachments.last
      PostingIdentity::Revocation.call!(actor: grantor, delegation: delegation.reload)

      expect do
        post '/api/v1/statuses', headers: headers, params: {
          status: 'Too late',
          visibility: 'public',
          posting_identity_id: delegated_id,
          media_ids: [media.id],
        }
      end.not_to change(Status, :count)

      expect(response).to have_http_status(403)
      expect(media.reload.account_id).to eq grantor.account.id
      expect(media.status_id).to be_nil
    end

    it 'lets media cleanup delete the file without deleting the audit identifier' do
      delegate!
      upload!
      media = grantor.account.media_attachments.last
      audit = PostingIdentityMedia.find_by!(media_attachment_id: media.id)

      expect { media.destroy! }.not_to raise_error

      expect(MediaAttachment.find_by(id: media.id)).to be_nil
      expect(PostingIdentityMedia.find(audit.id).media_attachment_id).to eq media.id
    end

    it 'rejects more images than the attachment limit' do
      delegate!
      ids = Array.new(Setting.attachments_max + 1) { |index| index + 1 }

      expect do
        post '/api/v1/statuses', headers: headers, params: {
          status: 'Too many',
          visibility: 'public',
          posting_identity_id: delegated_id,
          media_ids: ids,
        }
      end.not_to change(Status, :count)

      expect(response).to have_http_status(422)
    end
  end
end
