# frozen_string_literal: true

require 'rails_helper'

describe Admin::ModerationEvidenceSnapshotsController, type: :controller do
  render_views false

  let(:subject_a) { Fabricate(:moderation_subject) }
  let(:subject_b) { Fabricate(:moderation_subject) }
  let!(:snapshot_a) { Fabricate(:moderation_evidence_snapshot, subject: subject_a) }
  let!(:snapshot_b) { Fabricate(:moderation_evidence_snapshot, subject: subject_b) }

  context 'as an admin' do
    before { sign_in Fabricate(:user, admin: true) }

    describe 'GET #index' do
      it 'returns 200 and lists all snapshots' do
        get :index

        expect(response).to have_http_status(200)
        expect(assigns(:snapshots)).to include(snapshot_a, snapshot_b)
      end

      it 'filters by subject_id when given' do
        get :index, params: { subject_id: subject_a.id }

        expect(response).to have_http_status(200)
        expect(assigns(:subject)).to eq subject_a
        expect(assigns(:snapshots)).to include(snapshot_a)
        expect(assigns(:snapshots)).to_not include(snapshot_b)
      end
    end

    describe 'GET #show' do
      it 'returns 200 for a snapshot' do
        get :show, params: { id: snapshot_a.id }

        expect(response).to have_http_status(200)
        expect(assigns(:snapshot)).to eq snapshot_a
      end

      it 'resolves the negative-target subject sets' do
        snapshot_a.update!(fingerprint: {
          'linked_negative_target_subject_ids' => [subject_b.id],
          'correlated_negative_target_subject_ids' => [],
        })

        get :show, params: { id: snapshot_a.id }

        expect(assigns(:linked_subjects)).to eq(subject_b.id => subject_b)
      end
    end
  end

  context 'as a non-staff user' do
    before { sign_in Fabricate(:user) }

    it 'forbids the index' do
      get :index
      expect(response).to have_http_status(:forbidden)
    end

    it 'forbids show' do
      get :show, params: { id: snapshot_a.id }
      expect(response).to have_http_status(:forbidden)
    end
  end
end
