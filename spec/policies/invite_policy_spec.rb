# frozen_string_literal: true

require 'rails_helper'
require 'pundit/rspec'

RSpec.describe InvitePolicy do
  let(:subject) { described_class }
  let(:admin)   { Fabricate(:user, admin: true).account }
  let(:john)    { Fabricate(:user).account }

  around do |example|
    previous = Setting.min_invite_role
    example.run
  ensure
    Setting.min_invite_role = previous
    Rails.cache.clear
  end

  permissions :index?, :deactivate_all? do
    it 'permits an owner and denies an ordinary user' do
      expect(subject).to permit(admin, Invite)
      expect(subject).to_not permit(john, Invite)
    end
  end

  permissions :create? do
    it 'denies everyone, including Owner, when invites are disabled' do
      Setting.min_invite_role = 'disabled'
      UserRole::LegacySettingsSync.call

      expect(subject).to_not permit(admin, Invite)
      expect(subject).to_not permit(john, Invite)
    end

    it 'permits a functional user when Everyone has invite_users' do
      Setting.min_invite_role = 'user'
      UserRole::LegacySettingsSync.call

      expect(subject).to permit(john, Invite)
      expect(subject).to permit(admin, Invite)
    end

    it 'denies a silenced user' do
      Setting.min_invite_role = 'user'
      UserRole::LegacySettingsSync.call
      john.silence!

      expect(subject).to_not permit(john, Invite)
    end
  end

  permissions :destroy? do
    it 'permits the invite owner' do
      expect(subject).to permit(john, Fabricate(:invite, user: john.user))
    end

    it 'permits a role that can manage invites' do
      expect(subject).to permit(admin, Fabricate(:invite))
    end

    it 'denies an ordinary user who does not own the invite' do
      expect(subject).to_not permit(john, Fabricate(:invite))
    end
  end
end
