# frozen_string_literal: true

require 'rails_helper'
require 'pundit/rspec'

RSpec.describe AccountPolicy do
  let(:subject) { described_class }
  let(:admin)   { user_with_role('Owner').account }
  let(:john)    { Fabricate(:user).account }
  let(:alice)   { Fabricate(:user).account }

  permissions :index? do
    context 'staff' do
      it 'permits' do
        expect(subject).to permit(admin)
      end
    end

    context 'enabled moderator' do
      let(:moderator) { user_with_role('Moderator').account }

      it 'permits' do
        expect(subject).to permit(moderator)
      end
    end

    context 'not staff' do
      it 'denies' do
        expect(subject).to_not permit(john)
      end
    end

    context 'disabled admin' do
      let(:disabled_admin) { user_with_role('Owner', disabled: true).account }

      it 'denies' do
        expect(subject).to_not permit(disabled_admin)
      end
    end

    context 'disabled moderator' do
      let(:disabled_moderator) { user_with_role('Moderator', disabled: true).account }

      it 'denies' do
        expect(subject).to_not permit(disabled_moderator)
      end
    end
  end

  permissions :show?, :unsilence?, :unsensitive?, :remove_avatar?, :remove_header? do
    context 'staff' do
      it 'permits' do
        expect(subject).to permit(admin, alice)
      end
    end

    context 'not staff' do
      it 'denies' do
        expect(subject).to_not permit(john, alice)
      end
    end
  end

  permissions :unsuspend? do
    before do
      alice.suspend!
    end

    context 'staff' do
      it 'permits' do
        expect(subject).to permit(admin, alice)
      end
    end

    context 'not staff' do
      it 'denies' do
        expect(subject).to_not permit(john, alice)
      end
    end
  end

  permissions :redownload?, :subscribe?, :unsubscribe? do
    context 'admin' do
      it 'permits' do
        expect(subject).to permit(admin)
      end
    end

    context 'not admin' do
      it 'denies' do
        expect(subject).to_not permit(john)
      end
    end
  end

  permissions :suspend?, :silence? do
    let(:staff) { user_with_role('Owner').account }

    context 'staff' do
      context 'record is staff' do
        it 'denies' do
          expect(subject).to_not permit(admin, staff)
        end
      end

      context 'record is not staff' do
        it 'permits' do
          expect(subject).to permit(admin, john)
        end
      end
    end

    context 'not staff' do
      it 'denies' do
        expect(subject).to_not permit(john, Account)
      end
    end
  end

  permissions :memorialize? do
    let(:other_admin) { user_with_role('Owner').account }

    context 'admin' do
      context 'record is admin' do
        it 'denies' do
          expect(subject).to_not permit(admin, other_admin)
        end
      end

      context 'record is not admin' do
        it 'permits' do
          expect(subject).to permit(admin, john)
        end
      end
    end

    context 'not admin' do
      it 'denies' do
        expect(subject).to_not permit(john, Account)
      end
    end
  end
end
