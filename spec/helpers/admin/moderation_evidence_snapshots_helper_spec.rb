# frozen_string_literal: true

require 'rails_helper'

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

  describe '#moderation_boolean' do
    it 'renders localized yes/no and unknown' do
      expect(helper.moderation_boolean(true)).to eq I18n.t('admin.moderation_evidence_snapshots.boolean.affirmative')
      expect(helper.moderation_boolean(false)).to eq I18n.t('admin.moderation_evidence_snapshots.boolean.negative')
      expect(helper.moderation_boolean(nil)).to eq I18n.t('admin.moderation_evidence_snapshots.unknown')
    end
  end
end
