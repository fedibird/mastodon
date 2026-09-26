# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Webhook do
  let(:webhook) { Fabricate(:webhook) }

  describe 'secret generation' do
    it 'generates a secret of at least 12 characters' do
      record = described_class.new(url: 'https://example.com/hook', events: ['status.created'])

      expect(record).to be_valid
      expect(record.secret).to match(/\A\h{40}\z/)
    end
  end

  describe 'validations' do
    it 'rejects an invalid URL' do
      record = described_class.new(url: 'not a url', events: ['status.created'], secret: 'a' * 12)

      expect(record).to_not be_valid
      expect(record.errors[:url]).to be_present
    end

    it 'shows the generic URL message without a missing translation' do
      I18n.with_locale(:en) do
        record = described_class.new(url: 'not a url', events: ['status.created'], secret: 'a' * 12)
        record.validate

        expect(record.errors.full_messages.join).not_to include('translation missing')
        expect(record.errors[:url].join).to include(I18n.t('applications.invalid_url'))
      end

      I18n.with_locale(:ja) do
        record = described_class.new(url: 'not a url', events: ['status.created'], secret: 'a' * 12)
        record.validate

        expect(record.errors.full_messages.join).not_to include('translation missing')
        expect(record.errors[:url].join).to include(I18n.t('applications.invalid_url'))
      end
    end

    it 'rejects empty events' do
      record = described_class.new(url: 'https://example.com/hook', events: [], secret: 'a' * 12)

      expect(record).to_not be_valid
      expect(record.errors.added?(:events, :blank)).to be true
    end

    it 'rejects an unknown event' do
      record = described_class.new(url: 'https://example.com/hook', events: ['nope.nope'], secret: 'a' * 12)

      expect(record).to_not be_valid
      expect(record.errors.added?(:events, :invalid)).to be true
    end

    it 'strips blank and surrounding whitespace from events' do
      record = described_class.new(url: 'https://example.com/hook', events: [' status.created ', '', '  '], secret: 'a' * 12)

      expect(record).to be_valid
      expect(record.events).to eq ['status.created']
    end

    it 'rejects a secret shorter than 12 characters' do
      record = described_class.new(url: 'https://example.com/hook', events: ['status.created'], secret: 'short')

      expect(record).to_not be_valid
      expect(record.errors[:secret]).to be_present
    end

    it 'accepts a valid template' do
      record = described_class.new(url: 'https://example.com/hook', events: ['status.created'], template: '{"event":"{{event}}"}')

      expect(record).to be_valid
    end

    it 'rejects a malformed template' do
      record = described_class.new(url: 'https://example.com/hook', events: ['status.created'], template: '{{')

      expect(record).to_not be_valid
      expect(record.errors.added?(:template, :invalid)).to be true
    end

    it 'rejects events the current account cannot view' do
      role = UserRole.create!(name: 'Webhook only', position: 40, permissions_as_keys: ['manage_webhooks'])
      user = user_with_role(role)
      record = described_class.new(url: 'https://example.com/hook', events: ['account.created'])
      record.current_account = user.account

      expect(record).to_not be_valid
      expect(record.errors.added?(:events, :invalid_permissions)).to be true
    end

    it 'translates invalid_permissions in English and Japanese' do
      role = UserRole.create!(name: 'Webhook locale', position: 41, permissions_as_keys: ['manage_webhooks'])
      user = user_with_role(role)

      I18n.with_locale(:en) do
        record = described_class.new(url: 'https://example.com/hook', events: ['account.created'])
        record.current_account = user.account
        record.validate

        expect(record.errors.full_messages.join).not_to include('translation missing')
        expect(record.errors.full_messages.join).to include("cannot include events you don't have the rights to")
      end

      I18n.with_locale(:ja) do
        record = described_class.new(url: 'https://example.com/hook', events: ['account.created'])
        record.current_account = user.account
        record.validate

        expect(record.errors.full_messages.join).not_to include('translation missing')
        expect(record.errors.full_messages.join).to include('あなたが権利を持っていないイベントを含めることはできません')
      end
    end

    it 'accepts events the current account can view' do
      record = described_class.new(url: 'https://example.com/hook', events: ['account.created', 'report.created', 'status.created'])
      record.current_account = user_with_role('Owner').account

      expect(record).to be_valid
    end
  end

  describe '#rotate_secret!' do
    it 'changes the secret' do
      previous_value = webhook.secret
      webhook.rotate_secret!
      expect(webhook.secret).to_not be_blank
      expect(webhook.secret).to_not eq previous_value
      expect(webhook.secret).to match(/\A\h{40}\z/)
    end
  end

  describe '#enable!' do
    before do
      webhook.disable!
    end

    it 'enables the webhook' do
      webhook.enable!
      expect(webhook.enabled?).to be true
    end
  end

  describe '#disable!' do
    it 'disables the webhook' do
      webhook.disable!
      expect(webhook.enabled?).to be false
    end
  end

  describe '.permission_for_event' do
    it 'maps events to the v4.2.13 permissions' do
      expect(described_class.permission_for_event('account.approved')).to eq :manage_users
      expect(described_class.permission_for_event('account.created')).to eq :manage_users
      expect(described_class.permission_for_event('account.updated')).to eq :manage_users
      expect(described_class.permission_for_event('report.created')).to eq :manage_reports
      expect(described_class.permission_for_event('report.updated')).to eq :manage_reports
      expect(described_class.permission_for_event('status.created')).to eq :view_devops
      expect(described_class.permission_for_event('status.updated')).to eq :view_devops
    end
  end
end
