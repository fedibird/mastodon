# frozen_string_literal: true

require 'rails_helper'
require 'pundit/rspec'

RSpec.describe CanonicalEmailBlockPolicy do
  let(:subject) { described_class }
  let(:admin)   { user_with_role('Owner').account }
  let(:john)    { Fabricate(:user).account }

  permissions :index?, :show?, :test?, :create?, :destroy? do
    context 'admin' do
      it 'permits' do
        expect(subject).to permit(admin, CanonicalEmailBlock)
      end
    end

    context 'not admin' do
      it 'denies' do
        expect(subject).to_not permit(john, CanonicalEmailBlock)
      end
    end
  end
end
