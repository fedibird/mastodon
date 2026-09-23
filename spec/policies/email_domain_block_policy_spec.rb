# frozen_string_literal: true

require 'rails_helper'
require 'pundit/rspec'

RSpec.describe EmailDomainBlockPolicy do
  let(:subject) { described_class }
  let(:admin)   { user_with_role('Owner').account }
  let(:john)    { Fabricate(:user).account }

  permissions :index?, :show?, :create?, :destroy? do
    context 'admin' do
      it 'permits' do
        expect(subject).to permit(admin, EmailDomainBlock)
      end
    end

    context 'not admin' do
      it 'denies' do
        expect(subject).to_not permit(john, EmailDomainBlock)
      end
    end
  end
end
