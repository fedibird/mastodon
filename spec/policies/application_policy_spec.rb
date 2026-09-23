# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplicationPolicy do
  let(:policy) { described_class.new(user.account, nil) }
  let(:user) { Fabricate(:user, admin: true, moderator: false) }

  describe '#role' do
    it 'uses the effective role of a functional owner' do
      expect(policy.send(:role)).to eq user.user_role
      expect(policy.send(:role).can?(:administrator)).to be true
    end

    it 'is nobody when the user is disabled' do
      user.update_columns(disabled: true)

      expect(described_class.new(user.account, nil).send(:role)).to be_nobody
    end

    it 'is nobody when the user is unconfirmed' do
      user.update_columns(confirmed_at: nil)

      expect(described_class.new(user.account, nil).send(:role)).to be_nobody
    end

    it 'is nobody when the user is unapproved' do
      user.update_columns(approved: false)

      expect(described_class.new(user.account, nil).send(:role)).to be_nobody
    end

    it 'is nobody when the account is suspended' do
      user.account.update_columns(suspended_at: Time.now.utc)

      expect(described_class.new(user.account, nil).send(:role)).to be_nobody
    end

    it 'is nobody when the account is memorial' do
      user.account.update_columns(memorial: true)

      expect(described_class.new(user.account, nil).send(:role)).to be_nobody
    end

    it 'is nobody when the account has moved' do
      user.account.update_columns(moved_to_account_id: Fabricate(:account).id)

      expect(described_class.new(user.account, nil).send(:role)).to be_nobody
    end

    it 'is nobody without a user' do
      expect(described_class.new(nil, nil).send(:role)).to be_nobody
    end
  end
end
