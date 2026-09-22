# frozen_string_literal: true

require 'rails_helper'
require 'pundit/rspec'

RSpec.describe StatusPolicy, type: :model do # rubocop:disable Metrics/BlockLength
  subject { described_class }

  let(:admin) { Fabricate(:user, admin: true) }
  let(:alice) { Fabricate(:account, username: 'alice') }
  let(:bob) { Fabricate(:account, username: 'bob') }
  let(:status) { Fabricate(:status, account: alice) }

  permissions :show?, :reblog? do
    it 'grants access when no viewer' do
      expect(subject).to permit(nil, status)
    end

    it 'denies access when viewer is blocked' do
      block = Fabricate(:block)
      status.visibility = :private
      status.account = block.target_account

      expect(subject).to_not permit(block.account, status)
    end
  end

  permissions :subscribe? do
    it 'grants access when public and account is viewer' do
      viewer = Fabricate(:account)
      status.visibility = :public

      expect(subject).to permit(viewer, status)
    end

    it 'grants access when direct and viewer is mentioned' do
      status.visibility = :unlisted
      status.mentions = [Fabricate(:mention, account: alice)]

      expect(subject).to permit(alice, status)
    end

    it 'grants access when unlisted and account is following viewer' do
      follow = Fabricate(:follow)
      status.visibility = :unlisted
      status.account = follow.target_account

      expect(subject).to permit(follow.account, status)
    end

    it 'denies access when unlisted and account is not mentioned or following viewer' do
      viewer = Fabricate(:account)
      status.visibility = :unlisted

      expect(subject).to_not permit(viewer, status)
    end
  end

  permissions :show? do
    it 'grants access when direct and account is viewer' do
      status.visibility = :direct

      expect(subject).to permit(status.account, status)
    end

    it 'grants access when direct and viewer is mentioned' do
      status.visibility = :direct
      status.mentions = [Fabricate(:mention, account: alice)]

      expect(subject).to permit(alice, status)
    end

    it 'denies access when direct and viewer is not mentioned' do
      viewer = Fabricate(:account)
      status.visibility = :direct

      expect(subject).to_not permit(viewer, status)
    end

    it 'grants access when private and account is viewer' do
      status.visibility = :private

      expect(subject).to permit(status.account, status)
    end

    it 'grants access when private and account is following viewer' do
      follow = Fabricate(:follow)
      status.visibility = :private
      status.account = follow.target_account

      expect(subject).to permit(follow.account, status)
    end

    it 'grants access when private and viewer is mentioned' do
      status.visibility = :private
      status.mentions = [Fabricate(:mention, account: alice)]

      expect(subject).to permit(alice, status)
    end

    it 'denies access when private and viewer is not mentioned or followed' do
      viewer = Fabricate(:account)
      status.visibility = :private

      expect(subject).to_not permit(viewer, status)
    end
  end

  permissions :reblog? do
    it 'denies access when private' do
      viewer = Fabricate(:account)
      status.visibility = :private

      expect(subject).to_not permit(viewer, status)
    end

    it 'denies access when direct' do
      viewer = Fabricate(:account)
      status.visibility = :direct

      expect(subject).to_not permit(viewer, status)
    end
  end

  permissions :destroy?, :unreblog? do
    it 'grants access when account is deleter' do
      expect(subject).to permit(status.account, status)
    end

    it 'grants access when account is admin' do
      expect(subject).to permit(admin.account, status)
    end

    it 'denies access when account is not deleter' do
      expect(subject).to_not permit(bob, status)
    end

    it 'denies access when no deleter' do
      expect(subject).to_not permit(nil, status)
    end
  end

  permissions :favourite? do
    it 'grants access when viewer is not blocked' do
      follow         = Fabricate(:follow)
      status.account = follow.target_account

      expect(subject).to permit(follow.account, status)
    end

    it 'denies when viewer is blocked' do
      block          = Fabricate(:block)
      status.account = block.target_account

      expect(subject).to_not permit(block.account, status)
    end
  end

  permissions :index?, :moderate? do
    it 'grants access if staff' do
      expect(subject).to permit(admin.account)
    end

    it 'denies access unless staff' do
      expect(subject).to_not permit(alice)
    end
  end

  permissions :update? do
    it 'grants access to the owning account' do
      expect(subject).to permit(alice, status)
    end

    it 'denies access to staff who do not own the status' do
      expect(subject).to_not permit(admin.account, status)
    end

    it 'denies access to another account' do
      expect(subject).to_not permit(bob, status)
    end
  end
end
