# frozen_string_literal: true

require 'rails_helper'
require 'pundit/rspec'

RSpec.describe ActionReviewRequestPolicy do
  let(:subject) { described_class }
  let(:admin)   { Fabricate(:user, admin: true).account }
  let(:john)    { Fabricate(:user).account }

  permissions :index?, :show?, :approve?, :reject? do
    context 'staff?' do
      it 'permits' do
        expect(subject).to permit(admin, ActionReviewRequest)
      end
    end

    context 'enabled moderator' do
      let(:moderator) { Fabricate(:user, moderator: true).account }

      it 'permits' do
        expect(subject).to permit(moderator, ActionReviewRequest)
      end
    end

    context '!staff?' do
      it 'denies' do
        expect(subject).to_not permit(john, ActionReviewRequest)
      end
    end

    context 'disabled admin' do
      let(:disabled_admin) { Fabricate(:user, admin: true, disabled: true).account }

      it 'denies' do
        expect(subject).to_not permit(disabled_admin, ActionReviewRequest)
      end
    end

    context 'disabled moderator' do
      let(:disabled_moderator) { Fabricate(:user, moderator: true, disabled: true).account }

      it 'denies' do
        expect(subject).to_not permit(disabled_moderator, ActionReviewRequest)
      end
    end
  end
end
