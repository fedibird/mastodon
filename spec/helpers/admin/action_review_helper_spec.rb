# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Admin::ActionReviewHelper do
  describe '#action_review_queue_nav_label' do
    it 'omits a count when nothing is pending' do
      expect(helper.action_review_queue_nav_label).to eq I18n.t('admin.action_reviews.title')
    end

    it 'includes the pending count when rows exist' do
      actor = Fabricate(:account)
      resource = Fabricate(:account)
      ActionReviewRequest.create!(
        operation_type: 'invite_creation',
        state: :pending,
        actor_account: actor,
        resource: resource,
        trigger: 'policy',
        signal_level: 'none',
        policy_mode: 'always',
        policy_version: 'action-review-policy-v1',
        reason_codes: ['policy_always'],
        evidence: {},
        requested_at: Time.now.utc
      )

      expect(helper.action_review_queue_nav_label).to eq I18n.t('admin.action_reviews.title_with_count', count: 1)
    end
  end
end
