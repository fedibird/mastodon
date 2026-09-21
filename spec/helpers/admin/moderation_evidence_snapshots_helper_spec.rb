# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Admin::ModerationEvidenceSnapshotsHelper, type: :helper do
  describe '#moderation_subject_label' do
    it 'labels a local account by username' do
      account = Fabricate(:account, username: 'alice')
      subject = Fabricate(:moderation_subject, account: account, origin: :local)

      expect(helper.moderation_subject_label(subject)).to eq '@alice'
    end

    it 'labels a remote account by acct' do
      account = Fabricate(:account, username: 'bob', domain: 'remote.example')
      subject = Fabricate(:moderation_subject, account: account, origin: :remote, domain: 'remote.example')

      expect(helper.moderation_subject_label(subject)).to eq '@bob@remote.example'
    end

    it 'falls back to the domain for a detached remote subject' do
      subject = Fabricate(:moderation_subject, account: nil, origin: :remote, domain: 'gone.example')

      expect(helper.moderation_subject_label(subject)).to eq I18n.t('admin.moderation_evidence_snapshots.detached_remote_subject', domain: 'gone.example')
    end

    it 'falls back to a generic label for a detached local subject' do
      subject = Fabricate(:moderation_subject, account: nil, origin: :local, domain: nil)

      expect(helper.moderation_subject_label(subject)).to eq I18n.t('admin.moderation_evidence_snapshots.detached_local_subject')
    end
  end

  describe '#moderation_negative_targets' do
    it 'returns the none label for a blank set' do
      expect(helper.moderation_negative_targets([], {})).to eq I18n.t('admin.moderation_evidence_snapshots.none')
    end

    it 'renders resolved subjects and falls back to a raw id when unresolved' do
      account = Fabricate(:account, username: 'carol')
      subject = Fabricate(:moderation_subject, account: account, origin: :local)

      rendered = helper.moderation_negative_targets([subject.id, 999], { subject.id => subject })

      expect(rendered).to include('@carol')
      expect(rendered).to include('#999')
    end
  end

  describe '#moderation_snapshot_window' do
    it 'renders a full window as two formatted time tags with a separator' do
      started = Time.utc(2026, 9, 1, 0, 0, 0)
      ended = Time.utc(2026, 9, 21, 12, 0, 0)
      snapshot = Fabricate(:moderation_evidence_snapshot, window_start: started, window_end: ended)
      html = helper.moderation_snapshot_window(snapshot)
      nodes = Nokogiri::HTML.fragment(html).css('time.formatted')

      expect(html).to include(' – ')
      expect(nodes.size).to eq 2
      expect(nodes[0]['datetime']).to eq started.iso8601
      expect(nodes[1]['datetime']).to eq ended.iso8601
      expect(Time.iso8601(nodes[0]['datetime'])).to eq started
      expect(Time.iso8601(nodes[1]['datetime'])).to eq ended
    end

    it 'renders an end-only window with an ellipsis and one formatted time tag' do
      ended = Time.utc(2026, 9, 21, 12, 0, 0)
      snapshot = Fabricate(:moderation_evidence_snapshot, window_start: nil, window_end: ended)
      html = helper.moderation_snapshot_window(snapshot)
      nodes = Nokogiri::HTML.fragment(html).css('time.formatted')

      expect(html).to start_with('… – ')
      expect(nodes.size).to eq 1
      expect(nodes.first['datetime']).to eq ended.iso8601
    end

    it 'renders an all-time window without time tags' do
      snapshot = Fabricate(:moderation_evidence_snapshot, window_start: nil, window_end: nil)

      expect(helper.moderation_snapshot_window(snapshot)).to eq I18n.t('admin.moderation_evidence_snapshots.all_time')
    end
  end

  describe '#moderation_boolean' do
    it 'renders localized yes/no and unknown' do
      expect(helper.moderation_boolean(true)).to eq I18n.t('admin.moderation_evidence_snapshots.boolean.affirmative')
      expect(helper.moderation_boolean(false)).to eq I18n.t('admin.moderation_evidence_snapshots.boolean.negative')
      expect(helper.moderation_boolean(nil)).to eq I18n.t('admin.moderation_evidence_snapshots.unknown')
    end
  end
end
# rubocop:enable Metrics/BlockLength
