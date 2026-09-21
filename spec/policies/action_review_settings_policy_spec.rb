# frozen_string_literal: true

require 'rails_helper'
require 'pundit/rspec'

RSpec.describe ActionReviewSettingsPolicy do
  let(:subject) { described_class }
  let(:admin)   { Fabricate(:user, admin: true).account }
  let(:john)    { Fabricate(:user).account }

  permissions :update?, :show? do
    context 'admin?' do
      it 'permits' do
        expect(subject).to permit(admin, :action_review_settings)
      end
    end

    context 'moderator' do
      let(:moderator) { Fabricate(:user, moderator: true).account }

      it 'denies' do
        expect(subject).to_not permit(moderator, :action_review_settings)
      end
    end

    context '!admin?' do
      it 'denies' do
        expect(subject).to_not permit(john, :action_review_settings)
      end
    end

    context 'disabled admin' do
      let(:disabled_admin) { Fabricate(:user, admin: true, disabled: true).account }

      it 'denies' do
        expect(subject).to_not permit(disabled_admin, :action_review_settings)
      end
    end
  end
end
