require 'rails_helper'

RSpec.describe Api::V1::MediaController, type: :controller do
  render_views

  let(:user)  { Fabricate(:user, account: Fabricate(:account, username: 'alice')) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'write:media') }

  before do
    allow(controller).to receive(:doorkeeper_token) { token }
  end

  describe 'POST #create' do
    describe 'with paperclip errors' do
      context 'when imagemagick cant identify the file type' do
        before do
          expect_any_instance_of(Account).to receive_message_chain(:media_attachments, :create!).and_raise(Paperclip::Errors::NotIdentifiedByImageMagickError)
          post :create, params: { file: fixture_file_upload('attachment.jpg', 'image/jpeg') }
        end

        it 'returns http 422' do
          expect(response).to have_http_status(:unprocessable_entity)
        end
      end

      context 'when there is a generic error' do
        before do
          expect_any_instance_of(Account).to receive_message_chain(:media_attachments, :create!).and_raise(Paperclip::Error)
          post :create, params: { file: fixture_file_upload('attachment.jpg', 'image/jpeg') }
        end

        it 'returns http 422' do
          expect(response).to have_http_status(500)
        end
      end
    end

    context 'image/jpeg' do
      before do
        post :create, params: { file: fixture_file_upload('attachment.jpg', 'image/jpeg') }
      end

      it 'returns http success' do
        expect(response).to have_http_status(200)
      end

      it 'creates a media attachment' do
        expect(MediaAttachment.first).to_not be_nil
      end

      it 'uploads a file' do
        expect(MediaAttachment.first).to have_attached_file(:file)
      end

      it 'returns media ID in JSON' do
        expect(body_as_json[:id]).to eq MediaAttachment.first.id.to_s
      end
    end

    context 'image/gif' do
      before do
        post :create, params: { file: fixture_file_upload('attachment.gif', 'image/gif') }
      end

      it 'returns http success' do
        expect(response).to have_http_status(200)
      end

      it 'creates a media attachment' do
        expect(MediaAttachment.first).to_not be_nil
      end

      it 'uploads a file' do
        expect(MediaAttachment.first).to have_attached_file(:file)
      end

      it 'returns media ID in JSON' do
        expect(body_as_json[:id]).to eq MediaAttachment.first.id.to_s
      end
    end

    context 'video/webm' do
      before do
        post :create, params: { file: fixture_file_upload('attachment.webm', 'video/webm') }
      end

      it do
        # returns http success
        expect(response).to have_http_status(200)

        # creates a media attachment
        expect(MediaAttachment.first).to_not be_nil

        # uploads a file
        expect(MediaAttachment.first).to have_attached_file(:file)

        # returns media ID in JSON
        expect(body_as_json[:id]).to eq MediaAttachment.first.id.to_s
      end
    end
  end

  describe 'GET #show' do
    context 'when attached to a scheduled status' do
      let(:scheduled_status) { Fabricate(:scheduled_status, account: user.account) }
      let(:media) { Fabricate(:media_attachment, status: nil, account: user.account, scheduled_status: scheduled_status) }

      it 'returns the media attachment' do
        get :show, params: { id: media.id }

        expect(response).to have_http_status(200)
        expect(body_as_json[:id]).to eq media.id.to_s
      end
    end

    context 'when attached to somebody else\'s scheduled status' do
      let(:other) { Fabricate(:account) }
      let(:media) { Fabricate(:media_attachment, status: nil, account: other, scheduled_status: Fabricate(:scheduled_status, account: other)) }

      it 'returns http not found' do
        get :show, params: { id: media.id }

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe 'PUT #update' do
    context 'when somebody else\'s' do
      let(:media) { Fabricate(:media_attachment, status: nil) }

      it 'returns http not found' do
        put :update, params: { id: media.id, description: 'Lorem ipsum!!!' }
        expect(response).to have_http_status(:not_found)
      end
    end

    context 'when not attached to a status' do
      let(:media) { Fabricate(:media_attachment, status: nil, account: user.account) }

      it 'updates the description' do
        put :update, params: { id: media.id, description: 'Lorem ipsum!!!' }

        expect(response).to have_http_status(200)
        expect(media.reload.description).to eq 'Lorem ipsum!!!'
      end

      it 'updates the focus' do
        put :update, params: { id: media.id, focus: '0.5,-0.25' }

        expect(response).to have_http_status(200)
        expect(media.reload.file.meta.dig('focus', 'x')).to eq 0.5
        expect(media.file.meta.dig('focus', 'y')).to eq(-0.25)
      end

      it 'does not replace the original file' do
        original_name = media.file_file_name
        original_size = media.file_file_size

        put :update, params: { id: media.id, file: fixture_file_upload('attachment.gif', 'image/gif'), description: 'kept file' }

        expect(response).to have_http_status(200)
        media.reload
        expect(media.file_file_name).to eq original_name
        expect(media.file_file_size).to eq original_size
        expect(media.description).to eq 'kept file'
      end

      it 'permits thumbnail, description, and focus on update, and file on create' do
        controller.params = ActionController::Parameters.new(file: 'ignored', thumbnail: 'thumb', description: 'alt', focus: '0,0')

        expect(controller.send(:updateable_media_attachment_params).to_h.keys).to match_array(%w(thumbnail description focus))
        expect(controller.send(:media_attachment_params).to_h.keys).to include('file')
      end
    end

    context 'when attached to a status' do
      let(:media) { Fabricate(:media_attachment, status: Fabricate(:status), account: user.account) }

      it 'returns http not found' do
        put :update, params: { id: media.id, description: 'Lorem ipsum!!!' }
        expect(response).to have_http_status(:not_found)
      end
    end

    context 'when attached to a scheduled status' do
      let(:scheduled_status) { Fabricate(:scheduled_status, account: user.account) }
      let(:media) { Fabricate(:media_attachment, status: nil, account: user.account, scheduled_status: scheduled_status) }

      it 'updates the description without detaching the scheduled status' do
        put :update, params: { id: media.id, description: 'updated alt text' }

        expect(response).to have_http_status(200)
        media.reload
        expect(media.description).to eq 'updated alt text'
        expect(media.scheduled_status_id).to eq scheduled_status.id
        expect(media.status_id).to be_nil
      end

      it 'updates the focus' do
        put :update, params: { id: media.id, focus: '0.5,-0.25' }

        expect(response).to have_http_status(200)
        expect(media.reload.file.meta.dig('focus', 'x')).to eq 0.5
        expect(media.file.meta.dig('focus', 'y')).to eq(-0.25)
      end
    end

    context 'when attached to somebody else\'s scheduled status' do
      let(:other) { Fabricate(:account) }
      let(:media) { Fabricate(:media_attachment, status: nil, account: other, scheduled_status: Fabricate(:scheduled_status, account: other)) }

      it 'returns http not found' do
        put :update, params: { id: media.id, description: 'updated alt text' }

        expect(response).to have_http_status(:not_found)
        expect(media.reload.description).not_to eq 'updated alt text'
      end
    end
  end
end
