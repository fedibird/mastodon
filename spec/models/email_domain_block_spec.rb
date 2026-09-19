# frozen_string_literal: true

require 'rails_helper'

RSpec.describe EmailDomainBlock, type: :model do
  describe 'validations' do
    it 'has a valid fabricator' do
      email_domain_block = Fabricate.build(:email_domain_block)
      expect(email_domain_block).to be_valid
    end
  end

  describe 'associations' do
    it 'keeps parent and children' do
      parent = Fabricate(:email_domain_block, domain: 'example.com')
      child  = Fabricate(:email_domain_block, domain: '1.2.3.4', parent: parent)

      expect(parent.children).to eq [child]
      expect(child.parent).to eq parent
    end
  end

  describe 'with_dns_records' do
    it 'keeps the DNS expansion flag' do
      block = described_class.new(domain: 'example.com', with_dns_records: '1')

      expect(block.with_dns_records?).to be true
      expect(block.with_dns_records).to be true
    end
  end

  describe 'block?' do
    let(:now) { Time.utc(2026, 9, 19, 12, 0, 0) }

    around do |example|
      travel_to(now) { example.run }
    end

    it 'returns true if the domain is registered' do
      Fabricate(:email_domain_block, domain: 'example.com')
      expect(described_class.block?('nyarn@example.com')).to eq true
    end

    it 'returns false if the domain is not registered' do
      Fabricate(:email_domain_block, domain: 'example.com')
      expect(described_class.block?('nyarn@example.net')).to eq false
    end

    it 'matches an exact domain from a full e-mail address' do
      Fabricate(:email_domain_block, domain: 'example.com')
      expect(described_class.block?('alice@example.com')).to be true
    end

    it 'matches a blocked domain string' do
      Fabricate(:email_domain_block, domain: 'example.com')
      expect(described_class.block?('example.com')).to be true
    end

    it 'matches a subdomain of a blocked domain' do
      Fabricate(:email_domain_block, domain: 'example.com')
      expect(described_class.block?('alice@mail.example.com')).to be true
    end

    it 'matches a nested subdomain of a blocked domain' do
      Fabricate(:email_domain_block, domain: 'example.com')
      expect(described_class.block?('alice@foo.mail.example.com')).to be true
    end

    it 'does not match a lookalike domain' do
      Fabricate(:email_domain_block, domain: 'example.com')
      expect(described_class.block?('alice@notexample.com')).to be false
    end

    it 'matches when given an array of domains' do
      Fabricate(:email_domain_block, domain: 'mail.foo.com')
      expect(described_class.block?(%w(foo.com mail.foo.com))).to be true
    end

    it 'treats invalid e-mail input as blocked' do
      expect(described_class.block?('alice@')).to be true
    end

    it 'treats invalid domain input as blocked' do
      expect(described_class.block?(' ')).to be true
    end

    it 'records history for valid matches even when invalid input is also present' do
      block = Fabricate(:email_domain_block, domain: 'example.com')

      expect(described_class.block?(['alice@example.com', 'alice@'], attempt_ip: '192.0.2.1')).to be true
      expect(block.history.get(now).uses).to eq 1
      expect(block.history.get(now).accounts).to eq 1
    end

    describe 'hit history' do
      let!(:block) { Fabricate(:email_domain_block, domain: 'example.com') }

      it 'records uses and unique accounts for a first attempt' do
        expect(described_class.block?('alice@example.com', attempt_ip: '192.0.2.1')).to be true
        expect(block.history.get(now).uses).to eq 1
        expect(block.history.get(now).accounts).to eq 1
      end

      it 'increments uses but not accounts for a repeated IP' do
        described_class.block?('alice@example.com', attempt_ip: '192.0.2.1')
        described_class.block?('alice@example.com', attempt_ip: '192.0.2.1')

        expect(block.history.get(now).uses).to eq 2
        expect(block.history.get(now).accounts).to eq 1
      end

      it 'counts a different IP as another account' do
        described_class.block?('alice@example.com', attempt_ip: '192.0.2.1')
        described_class.block?('alice@example.com', attempt_ip: '192.0.2.2')

        expect(block.history.get(now).uses).to eq 2
        expect(block.history.get(now).accounts).to eq 2
      end

      it 'does not record history without an attempt IP' do
        described_class.block?('alice@example.com')

        expect(block.history.get(now).uses).to eq 0
        expect(block.history.get(now).accounts).to eq 0
      end
    end
  end
end
