# frozen_string_literal: true

require 'rails_helper'
require 'pundit/rspec'

RSpec.describe InvitePolicy do
  let(:subject) { described_class }
  let(:admin)   { user_with_role('Owner').account }
  let(:john)    { Fabricate(:user).account }

  def set_everyone_invite(enabled)
    flag = UserRole::FLAGS[:invite_users]
    everyone = UserRole.everyone
    permissions = if enabled
                    everyone.permissions | flag
                  else
                    everyone.permissions & ~flag
                  end
    everyone.update!(permissions: permissions)
  end

  permissions :index?, :deactivate_all? do
    it 'permits an owner and denies an ordinary user' do
      expect(subject).to permit(admin, Invite)
      expect(subject).to_not permit(john, Invite)
    end
  end

  permissions :create? do
    it 'permits Owner and denies an ordinary user when Everyone cannot invite' do
      # disabled used to block Owner as well. Owner keeps invite_users through
      # the administrator flag after that setting stops being a global guard.
      set_everyone_invite(false)

      expect(subject).to permit(admin, Invite)
      expect(subject).to_not permit(john, Invite)
    end

    it 'permits a functional user when Everyone has invite_users' do
      set_everyone_invite(true)

      expect(subject).to permit(john, Invite)
      expect(subject).to permit(admin, Invite)
    end

    it 'denies a silenced user' do
      set_everyone_invite(true)
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
