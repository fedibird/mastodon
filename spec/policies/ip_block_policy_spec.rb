# frozen_string_literal: true

require 'rails_helper'
require 'pundit/rspec'

RSpec.describe IpBlockPolicy do
  let(:subject) { described_class }
  let(:admin)   { user_with_role('Owner').account }
  let(:john)    { Fabricate(:user).account }

  permissions :index?, :show?, :create?, :update?, :destroy? do
    context 'admin' do
      it 'permits' do
        expect(subject).to permit(admin, IpBlock)
      end
    end

    context 'moderator' do
      let(:moderator) { user_with_role('Moderator').account }

      it 'denies' do
        expect(subject).to_not permit(moderator, IpBlock)
      end
    end

    context 'not admin' do
      it 'denies' do
        expect(subject).to_not permit(john, IpBlock)
      end
    end

    context 'disabled admin' do
      let(:disabled_admin) { user_with_role('Owner', disabled: true).account }

      it 'denies' do
        expect(subject).to_not permit(disabled_admin, IpBlock)
      end
    end
  end
end
