# frozen_string_literal: true

require 'rails_helper'
require 'pundit/rspec'

RSpec.describe DomainAllowPolicy do
  let(:subject) { described_class }
  let(:admin)   { user_with_role('Owner').account }
  let(:moderator) { user_with_role('Moderator').account }
  let(:john)    { Fabricate(:user).account }

  permissions :index?, :show?, :create?, :destroy? do
    context 'admin' do
      it 'permits' do
        expect(subject).to permit(admin, DomainAllow)
      end
    end

    context 'moderator' do
      it 'denies' do
        expect(subject).to_not permit(moderator, DomainAllow)
      end
    end

    context 'not admin' do
      it 'denies' do
        expect(subject).to_not permit(john, DomainAllow)
      end
    end

    context 'disabled admin' do
      let(:disabled_admin) { user_with_role('Owner', disabled: true).account }

      it 'denies' do
        expect(subject).to_not permit(disabled_admin, DomainAllow)
      end
    end
  end
end
