# frozen_string_literal: true

require 'rails_helper'

describe Admin::ModerationMetricsController, type: :controller do
  render_views false

  let(:subject_record) { Fabricate(:moderation_subject) }

  context 'as an admin' do
    before { sign_in Fabricate(:user, admin: true) }

    describe 'GET #show' do
      it 'returns 200 and assigns the computed metrics for the subject' do
        get :show, params: { id: subject_record.id }

        expect(response).to have_http_status(200)
        expect(assigns(:subject)).to eq subject_record
        expect(assigns(:metrics)['subject_id']).to eq subject_record.id
        expect(assigns(:metrics)['windows']).to include('1h', '24h', '30d')
      end

      it 'fails closed with 404 for a stale subject id' do
        get :show, params: { id: ModerationSubject.maximum(:id).to_i + 1 }

        expect(response).to have_http_status(404)
        expect(assigns(:metrics)).to be_nil
      end
    end
  end

  context 'as a non-staff user' do
    before { sign_in Fabricate(:user) }

    it 'is forbidden' do
      get :show, params: { id: subject_record.id }
      expect(response).to have_http_status(:forbidden)
    end
  end
end
