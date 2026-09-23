# frozen_string_literal: true

require 'rails_helper'
require 'pundit/rspec'

RSpec.describe UserPolicy do
  let(:subject) { described_class }
  let(:admin)   { user_with_role('Owner').account }
  let(:john)    { Fabricate(:user).account }

  permissions :reset_password?, :change_email? do
    context 'staff?' do
      context '!record.staff?' do
        it 'permits' do
          expect(subject).to permit(admin, john.user)
        end
      end

      context 'record.staff?' do
        it 'denies' do
          expect(subject).to_not permit(admin, admin.user)
        end
      end
    end

    context '!staff?' do
      it 'denies' do
        expect(subject).to_not permit(john, User)
      end
    end
  end

  permissions :disable_2fa? do
    context 'admin?' do
      context '!record.staff?' do
        it 'permits' do
          expect(subject).to permit(admin, john.user)
        end
      end

      context 'record.staff?' do
        it 'denies' do
          expect(subject).to_not permit(admin, admin.user)
        end
      end
    end

    context '!admin?' do
      it 'denies' do
        expect(subject).to_not permit(john, User)
      end
    end
  end

  permissions :confirm? do
    context 'staff?' do
      context '!record.confirmed?' do
        it 'permits' do
          john.user.update(confirmed_at: nil)
          expect(subject).to permit(admin, john.user)
        end
      end

      context 'record.confirmed?' do
        it 'denies' do
          john.user.confirm!
          expect(subject).to_not permit(admin, john.user)
        end
      end
    end

    context '!staff?' do
      it 'denies' do
        expect(subject).to_not permit(john, User)
      end
    end
  end

  permissions :enable? do
    context 'staff?' do
      it 'permits' do
        expect(subject).to permit(admin, User)
      end
    end

    context '!staff?' do
      it 'denies' do
        expect(subject).to_not permit(john, User)
      end
    end
  end

  permissions :disable? do
    context 'staff?' do
      context '!record.admin?' do
        it 'permits' do
          expect(subject).to permit(admin, john.user)
        end
      end

      context 'record.admin?' do
        it 'denies' do
          expect(subject).to_not permit(admin, admin.user)
        end
      end
    end

    context '!staff?' do
      it 'denies' do
        expect(subject).to_not permit(john, User)
      end
    end
  end

  permissions :change_role? do
    it 'permits an actor who outranks the target and can manage roles' do
      expect(subject).to permit(admin, john.user)
    end

    it 'denies a peer and an actor without manage_roles' do
      expect(subject).to_not permit(admin, admin.user)
      expect(subject).to_not permit(john, john.user)
    end
  end
end
