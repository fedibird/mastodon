# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CanonicalEmailBlock, type: :model do
  describe '#email=' do
    let(:target_hash) { '973dfe463ec85785f5f95af5ba3906eedb2d931c24e69824a89ea65dba4e813b' }

    it 'sets canonical_email_hash' do
      subject.email = 'test@example.com'
      expect(subject.canonical_email_hash).to eq target_hash
    end

    it 'sets the same hash even with dot permutations' do
      subject.email = 't.e.s.t@example.com'
      expect(subject.canonical_email_hash).to eq target_hash
    end

    it 'sets the same hash even with extensions' do
      subject.email = 'test+mastodon1@example.com'
      expect(subject.canonical_email_hash).to eq target_hash
    end

    it 'sets the same hash with different casing' do
      subject.email = 'Test@EXAMPLE.com'
      expect(subject.canonical_email_hash).to eq target_hash
    end
  end

  describe 'validations' do
    it 'allows a manual block without a reference account' do
      block = described_class.new(email: 'manual@example.com', reference_account: nil)

      expect(block).to be_valid
      expect(block.save).to be true
      expect(block.reference_account_id).to be_nil
    end

    it 'still allows an account-linked block' do
      account = Fabricate(:account)
      block = described_class.new(email: 'linked@example.com', reference_account: account)

      expect(block).to be_valid
      expect(block.save).to be true
      expect(block.reference_account).to eq account
    end

    it 'validates uniqueness of canonical_email_hash' do
      described_class.create!(email: 'foo@example.com')
      duplicate = described_class.new(email: 'f.oo+test@example.com')

      expect(duplicate).to be_invalid
      expect(duplicate.errors[:canonical_email_hash]).to be_present
    end
  end

  describe '.matching_email' do
    let!(:block) { Fabricate(:canonical_email_block, email: 'foo@bar.com', reference_account: nil) }

    it 'finds the block for canonical variants' do
      expect(described_class.matching_email('foo@bar.com')).to contain_exactly(block)
      expect(described_class.matching_email('f.oo@bar.com')).to contain_exactly(block)
      expect(described_class.matching_email('foo+spam@bar.com')).to contain_exactly(block)
      expect(described_class.matching_email('Foo@BAR.com')).to contain_exactly(block)
    end

    it 'does not find a different email' do
      expect(described_class.matching_email('hoge@bar.com')).to be_empty
    end
  end

  describe '.block?' do
    let!(:canonical_email_block) { Fabricate(:canonical_email_block, email: 'foo@bar.com') }

    it 'returns true for the same email' do
      expect(described_class.block?('foo@bar.com')).to be true
    end

    it 'returns true for the same email with dots' do
      expect(described_class.block?('f.oo@bar.com')).to be true
    end

    it 'returns true for the same email with extensions' do
      expect(described_class.block?('foo+spam@bar.com')).to be true
    end

    it 'returns false for different email' do
      expect(described_class.block?('hoge@bar.com')).to be false
    end
  end

  describe '#to_log_human_identifier' do
    it 'returns the canonical email hash' do
      block = described_class.new(email: 'test@example.com')
      expect(block.to_log_human_identifier).to eq '973dfe463ec85785f5f95af5ba3906eedb2d931c24e69824a89ea65dba4e813b'
    end
  end

  describe 'fabricator' do
    it 'creates multiple unique records' do
      expect { Fabricate.times(5, :canonical_email_block) }.to change(described_class, :count).by(5)
    end
  end
end
