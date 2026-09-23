# frozen_string_literal: true

require 'rails_helper'

describe Admin::ModerationMetricsController, type: :controller do
  render_views false

  let(:subject_record) { Fabricate(:moderation_subject) }

  context 'as an admin' do
    before { sign_in user_with_role('Owner') }

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

      context 'with rendered timestamps' do
        render_views

        def stub_webpacker_manifest
          manifest = Webpacker.instance.manifest
          resolver = ->(name, **opts) { opts[:with_integrity] ? ["/packs-test/#{name}", nil] : "/packs-test/#{name}" }
          allow(manifest).to receive(:lookup!, &resolver)
          allow(manifest).to receive(:lookup, &resolver)
        end

        before { stub_webpacker_manifest }

        it 'renders generated_at and latest_import_at as time.formatted' do
          imported_at = Time.utc(2026, 9, 21, 8, 0, 0)
          FollowImportBatch.create!(
            subject: subject_record,
            imported_at: imported_at,
            mode: :merge,
            target_count: 0,
            resolved_target_count: 0,
            unresolved_target_count: 0
          )

          travel_to Time.utc(2026, 9, 21, 12, 0, 0) do
            get :show, params: { id: subject_record.id }
          end

          expect(response).to have_http_status(200)
          expect(response.body).to include(%(<time class="formatted" datetime="#{Time.utc(2026, 9, 21, 12, 0, 0).iso8601}"></time>))
          expect(response.body).to include(%(<time class="formatted" datetime="#{imported_at.iso8601}"></time>))
        end
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
