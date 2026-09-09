require 'rails_helper'

RSpec.describe Moderation::RetentionCleanup do
  describe '.events_without_retained_participant' do
    it 'evaluates retained subjects in SQL via NOT EXISTS' do
      sql = described_class.events_without_retained_participant(
        ModerationInteractionEvent,
        :actor_subject_id,
        :target_subject_id,
        Time.now.utc
      ).to_sql

      expect(sql).to include('NOT EXISTS')
      expect(sql).to include('moderation_subjects')
      expect(sql).to include('retention_until')
      expect(sql).to include('moderation_interaction_events.actor_subject_id')
      expect(sql).to include('moderation_interaction_events.target_subject_id')
      expect(sql).to_not match(/NOT IN \s*\(/i)
    end

    it 'includes events whose remaining participants are expired or NULL' do
      ClimateControl.modify MODERATION_LEDGER_RETENTION_DAYS: '30' do
        retained = Fabricate(:moderation_subject)
        expired  = Fabricate(:moderation_subject, deleted_at: 40.days.ago, retention_until: 10.days.ago)
        kept = Fabricate(:moderation_interaction_event, actor_subject: retained, target_subject: expired)
        orphan = Fabricate(:moderation_interaction_event, actor_subject: expired, target_subject: expired)
        orphan.update_columns(actor_subject_id: nil)

        scope = described_class.events_without_retained_participant(
          ModerationInteractionEvent,
          :actor_subject_id,
          :target_subject_id,
          Time.now.utc
        )

        expect(scope).to include(orphan)
        expect(scope).to_not include(kept)
      end
    end
  end
end
