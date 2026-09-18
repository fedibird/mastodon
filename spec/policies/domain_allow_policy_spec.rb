# frozen_string_literal: true

require 'rails_helper'
require 'pundit/rspec'

RSpec.describe DomainAllowPolicy do
  let(:subject) { described_class }
  let(:admin)   { Fabricate(:user, admin: true).account }
  let(:moderator) { Fabricate(:user, moderator: true).account }
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
  end
end
