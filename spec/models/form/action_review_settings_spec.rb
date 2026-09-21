# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Form::ActionReviewSettings do
  around do |example|
    example.run
  ensure
    Setting.where(var: 'action_review_policies').delete_all
    Rails.cache.clear
  end

  it 'loads defaults as off' do
    form = described_class.new

    expect(form.follow_import).to eq 'off'
    expect(form.account_migration).to eq 'off'
    expect(form.invite_creation).to eq 'off'
    expect(form.status_import).to eq 'off'
  end

  it 'saves supported modes and updates Setting' do
    form = described_class.new(
      follow_import: 'medium',
      account_migration: 'always',
      invite_creation: 'off',
      status_import: 'off'
    )

    expect { form.save }.not_to change(ActionReviewRequest, :count)
    expect(form.save).to be true
    expect(Setting['action_review_policies']).to include(
      'follow_import' => 'medium',
      'account_migration' => 'always',
      'invite_creation' => 'off',
      'status_import' => 'off'
    )
    expect(ActionReview::PolicySettings.mode_for('follow_import')).to eq 'medium'
  end

  it 'rejects an unsupported detectorless mode and does not persist it' do
    form = described_class.new(invite_creation: 'medium')

    expect(form.save).to be false
    expect(form.errors[:invite_creation]).to be_present
    expect(Setting['action_review_policies']['invite_creation']).to eq 'off'
  end

  it 'preserves registered keys that the form is not changing' do
    Setting.where(var: 'action_review_policies').first_or_initialize(var: 'action_review_policies').update!(
      value: {
        'follow_import' => 'high',
        'account_migration' => 'always',
        'invite_creation' => 'off',
        'status_import' => 'off',
        'future_op' => 'always',
      }
    )

    form = described_class.new(follow_import: 'low')
    expect(form.save).to be true

    policies = Setting['action_review_policies']
    expect(policies['follow_import']).to eq 'low'
    expect(policies['account_migration']).to eq 'always'
    expect(policies['future_op']).to eq 'always'
  end
end
