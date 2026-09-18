# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplicationPolicy do
  subject { described_class.new(account, nil) }

  let(:account) { user.account }
  let(:user) { Fabricate(:user, admin: true, moderator: false) }

  describe '#admin?' do
    it 'permits an enabled admin' do
      expect(subject.admin?).to be true
    end

    it 'denies a disabled admin' do
      user.disable!
      expect(described_class.new(user.account, nil).admin?).to be false
    end
  end

  describe '#moderator?' do
    let(:user) { Fabricate(:user, moderator: true, admin: false) }

    it 'permits an enabled moderator' do
      expect(subject.moderator?).to be true
    end

    it 'denies a disabled moderator' do
      user.disable!
      expect(described_class.new(user.account, nil).moderator?).to be false
    end
  end

  describe '#staff?' do
    it 'permits an enabled admin' do
      expect(subject.staff?).to be true
    end

    context 'with an enabled moderator' do
      let(:user) { Fabricate(:user, moderator: true, admin: false) }

      it 'permits' do
        expect(subject.staff?).to be true
      end
    end

    it 'denies a disabled admin' do
      user.disable!
      expect(described_class.new(user.account, nil).staff?).to be false
    end
  end
end
