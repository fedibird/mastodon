# frozen_string_literal: true

require 'rails_helper'
require 'pundit/rspec'

describe WebhookPolicy do
  let(:policy) { described_class }
  let(:admin)  { user_with_role('Admin').account }
  let(:owner)  { user_with_role('Owner').account }
  let(:john)   { Fabricate(:user).account }

  permissions :index?, :create?, :show?, :enable?, :disable?, :rotate_secret? do
    let(:webhook) { Fabricate(:webhook, events: ['account.created', 'report.created']) }

    context 'with an admin' do
      it 'permits' do
        expect(policy).to permit(admin, webhook)
      end
    end

    context 'with manage_webhooks but without the event permissions' do
      let(:operator) do
        role = UserRole.create!(name: 'Webhook operator', position: 40, permissions_as_keys: ['manage_webhooks'])
        user_with_role(role).account
      end

      it 'permits' do
        expect(policy).to permit(operator, webhook)
      end
    end

    context 'with a non-admin' do
      it 'denies' do
        expect(policy).to_not permit(john, webhook)
      end
    end
  end

  permissions :update?, :destroy? do
    let(:webhook) { Fabricate(:webhook, events: ['account.created', 'report.created']) }

    context 'with an admin who can see every subscribed event' do
      it 'permits' do
        expect(policy).to permit(admin, webhook)
      end
    end

    context 'with manage_webhooks but without the event permissions' do
      let(:operator) do
        role = UserRole.create!(name: 'Webhook operator limited', position: 41, permissions_as_keys: ['manage_webhooks'])
        user_with_role(role).account
      end

      it 'denies' do
        expect(policy).to_not permit(operator, webhook)
      end
    end

    context 'with a non-admin' do
      it 'denies' do
        expect(policy).to_not permit(john, webhook)
      end
    end

    context 'with status events' do
      let(:webhook) { Fabricate(:webhook, events: ['status.created']) }

      it 'permits an owner' do
        expect(policy).to permit(owner, webhook)
      end

      it 'denies an admin without view_devops' do
        expect(policy).to_not permit(admin, webhook)
      end
    end
  end
end
