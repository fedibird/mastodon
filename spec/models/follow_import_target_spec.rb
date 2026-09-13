# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImportTarget do
  let(:batch) do
    FollowImportBatch.create!(subject: Fabricate(:moderation_subject), imported_at: Time.now.utc, mode: :merge,
                              target_count: 0, resolved_target_count: 0, unresolved_target_count: 0)
  end

  describe 'execution state' do
    it 'defaults to pending (legacy rows are safe)' do
      target = batch.targets.create!(target_subject: Fabricate(:moderation_subject), position: 0)
      expect(target.state).to eq 'pending'
      expect(target.terminal?).to be false
    end

    it 'marks terminal states as terminal and others as not' do
      %w(accepted rejected completed_no_response delivery_failed).each_with_index do |state, i|
        target = batch.targets.create!(target_subject: Fabricate(:moderation_subject), position: i, state: state)
        expect(target.terminal?).to be true
      end

      %w(pending queued awaiting_delivery awaiting_response).each_with_index do |state, i|
        target = batch.targets.create!(target_subject: Fabricate(:moderation_subject), position: 100 + i, state: state)
        expect(target.terminal?).to be false
      end
    end

    it 'scopes terminal / non_terminal correctly' do
      accepted = batch.targets.create!(target_subject: Fabricate(:moderation_subject), position: 0, state: :accepted)
      pending  = batch.targets.create!(target_subject: Fabricate(:moderation_subject), position: 1, state: :pending)

      expect(FollowImportTarget.terminal).to include(accepted)
      expect(FollowImportTarget.terminal).to_not include(pending)
      expect(FollowImportTarget.non_terminal).to include(pending)
    end

    it 'finds response-overdue awaiting_response targets' do
      overdue = batch.targets.create!(target_subject: Fabricate(:moderation_subject), position: 0, state: :awaiting_response, response_deadline_at: 1.hour.ago)
      future  = batch.targets.create!(target_subject: Fabricate(:moderation_subject), position: 1, state: :awaiting_response, response_deadline_at: 1.hour.from_now)

      expect(FollowImportTarget.response_overdue).to include(overdue)
      expect(FollowImportTarget.response_overdue).to_not include(future)
    end
  end

  describe 'unresolved-target semantics are preserved' do
    it 'allows a target with only a target_key_hash (unresolved)' do
      target = batch.targets.create!(target_key_hash: 'deadbeef', position: 0)
      expect(target).to be_valid
      expect(target.resolved?).to be false
      expect(target.state).to eq 'pending'
    end
  end

  describe 'no raw imported address is retained' do
    it 'does not add any plaintext address/acct column' do
      forbidden = FollowImportTarget.column_names.grep(/acct|address|username|handle/i)
      expect(forbidden).to be_empty
    end
  end
end
