# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable Metrics/BlockLength
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

      it 'fails closed with 404 for a stale subject_id instead of widening to the global list' do
        stale_id = ModerationSubject.maximum(:id).to_i + 1

        get :index, params: { subject_id: stale_id }

        expect(response).to have_http_status(404)
        # The action aborted before building a scope, so it never fell back to
        # the unfiltered global snapshot list.
        expect(assigns(:snapshots)).to be_nil
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

      context 'with rendered timestamps' do
        render_views

        def stub_webpacker_manifest
          manifest = Webpacker.instance.manifest
          resolver = ->(name, **opts) { opts[:with_integrity] ? ["/packs-test/#{name}", nil] : "/packs-test/#{name}" }
          allow(manifest).to receive(:lookup!, &resolver)
          allow(manifest).to receive(:lookup, &resolver)
        end

        before { stub_webpacker_manifest }

        it 'renders snapshot created_at and action performed_at as time.formatted' do
          created_at = Time.utc(2026, 9, 20, 16, 0, 0)
          performed_at = Time.utc(2026, 9, 20, 15, 0, 0)
          snapshot = Fabricate(:moderation_evidence_snapshot, created_at: created_at)
          Fabricate(
            :moderation_action,
            subject: snapshot.subject,
            evidence_snapshot: snapshot,
            action_type: :suspend,
            performed_at: performed_at
          )

          get :index
          expect(response.body).to include(%(<time class="formatted" datetime="#{created_at.iso8601}"></time>))

          get :show, params: { id: snapshot.id }
          expect(response.body).to include(%(<time class="formatted" datetime="#{created_at.iso8601}"></time>))
          expect(response.body).to include(%(<time class="formatted" datetime="#{performed_at.iso8601}"></time>))
        end
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
# rubocop:enable Metrics/BlockLength
