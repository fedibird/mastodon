# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BlacklistedEmailValidator, type: :validator do
  describe '#validate' do
    let(:user)   { double(email: 'info@mail.com', sign_up_ip: '1.2.3.4', errors: errors) }
    let(:errors) { double(add: nil) }

    before do
      allow(user).to receive(:valid_invitation?) { false }
      allow_any_instance_of(described_class).to receive(:blocked_email_provider?) { blocked_email }
    end

    subject { described_class.new.validate(user); errors }

    context 'when e-mail provider is blocked' do
      let(:blocked_email) { true }

      it 'adds error' do
        expect(subject).to have_received(:add).with(:email, :blocked)
      end
    end

    context 'when e-mail provider is not blocked' do
      let(:blocked_email) { false }

      it 'does not add errors' do
        expect(subject).not_to have_received(:add).with(:email, :blocked)
      end

      context 'when canonical e-mail is blocked' do
        let(:other_user) { Fabricate(:user, email: 'i.n.f.o@mail.com') }

        before do
          other_user.account.suspend!
        end

        it 'adds error' do
          expect(subject).to have_received(:add).with(:email, :taken)
        end
      end
    end
  end

  describe 'email domain block history' do
    let(:errors) { double(add: nil) }
    let(:now) { Time.utc(2026, 9, 19, 12, 0, 0) }

    around do |example|
      travel_to(now) { example.run }
    end

    it 'blocks the e-mail and records history when the domain is blocked' do
      block = Fabricate(:email_domain_block, domain: 'example.com')
      user  = double(email: 'alice@example.com', sign_up_ip: '192.0.2.1', errors: errors, valid_invitation?: false)

      described_class.new.validate(user)

      expect(errors).to have_received(:add).with(:email, :blocked)
      expect(block.history.get(now).uses).to eq 1
      expect(block.history.get(now).accounts).to eq 1
    end

    it 'does not record history on an unrelated block' do
      block = Fabricate(:email_domain_block, domain: 'other.example')
      user  = double(email: 'alice@example.com', sign_up_ip: '192.0.2.1', errors: errors, valid_invitation?: false)

      described_class.new.validate(user)

      expect(errors).not_to have_received(:add).with(:email, :blocked)
      expect(block.history.get(now).uses).to eq 0
    end

    it 'keeps invitation bypass semantics' do
      block = Fabricate(:email_domain_block, domain: 'example.com')
      user  = double(email: 'alice@example.com', sign_up_ip: '192.0.2.1', errors: errors, valid_invitation?: true)

      described_class.new.validate(user)

      expect(errors).not_to have_received(:add)
      expect(block.history.get(now).uses).to eq 0
    end
  end
end
