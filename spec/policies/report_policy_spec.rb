# frozen_string_literal: true

require 'rails_helper'
require 'pundit/rspec'

RSpec.describe ReportPolicy do
  let(:subject) { described_class }
  let(:admin)   { Fabricate(:user, admin: true).account }
  let(:john)    { Fabricate(:user).account }

  permissions :update?, :index?, :show? do
    context 'staff?' do
      it 'permits' do
        expect(subject).to permit(admin, Report)
      end
    end

    context 'enabled moderator' do
      let(:moderator) { Fabricate(:user, moderator: true).account }

      it 'permits' do
        expect(subject).to permit(moderator, Report)
      end
    end

    context '!staff?' do
      it 'denies' do
        expect(subject).to_not permit(john, Report)
      end
    end

    context 'disabled admin' do
      let(:disabled_admin) { Fabricate(:user, admin: true, disabled: true).account }

      it 'denies' do
        expect(subject).to_not permit(disabled_admin, Report)
      end
    end

    context 'disabled moderator' do
      let(:disabled_moderator) { Fabricate(:user, moderator: true, disabled: true).account }

      it 'denies' do
        expect(subject).to_not permit(disabled_moderator, Report)
      end
    end
  end
end
