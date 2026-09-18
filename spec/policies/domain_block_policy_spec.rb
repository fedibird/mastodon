# frozen_string_literal: true

require 'rails_helper'
require 'pundit/rspec'

RSpec.describe DomainBlockPolicy do
  let(:subject) { described_class }
  let(:admin)   { Fabricate(:user, admin: true).account }
  let(:john)    { Fabricate(:user).account }

  permissions :index?, :show?, :create?, :update?, :destroy? do
    context 'admin' do
      it 'permits' do
        expect(subject).to permit(admin, DomainBlock)
      end
    end

    context 'moderator' do
      let(:moderator) { Fabricate(:user, moderator: true).account }

      it 'denies' do
        expect(subject).to_not permit(moderator, DomainBlock)
      end
    end

    context 'not admin' do
      it 'denies' do
        expect(subject).to_not permit(john, DomainBlock)
      end
    end

    context 'disabled admin' do
      let(:disabled_admin) { Fabricate(:user, admin: true, disabled: true).account }

      it 'denies' do
        expect(subject).to_not permit(disabled_admin, DomainBlock)
      end
    end
  end
end
