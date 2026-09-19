# frozen_string_literal: true

require 'rails_helper'

RSpec.describe IpBlock, type: :model do # rubocop:disable Metrics/BlockLength
  describe 'severity enum' do
    it 'maps sign_up_requires_approval to 5000' do
      expect(described_class.severities[:sign_up_requires_approval]).to eq 5000
    end

    it 'maps sign_up_block to 5500' do
      expect(described_class.severities[:sign_up_block]).to eq 5500
    end

    it 'maps no_access to 9999' do
      expect(described_class.severities[:no_access]).to eq 9999
    end
  end

  describe 'validations' do
    it 'is invalid without an IP' do
      ip_block = Fabricate.build(:ip_block, ip: nil, severity: :no_access)
      ip_block.valid?
      expect(ip_block).to model_have_error_on_field(:ip)
    end

    it 'is invalid without a severity' do
      ip_block = Fabricate.build(:ip_block, ip: '192.0.2.1', severity: nil)
      ip_block.valid?
      expect(ip_block).to model_have_error_on_field(:severity)
    end

    it 'is invalid with a duplicate exact IP' do
      Fabricate(:ip_block, ip: '192.0.2.1', severity: :no_access)
      duplicate = Fabricate.build(:ip_block, ip: '192.0.2.1', severity: :sign_up_block)
      duplicate.valid?
      expect(duplicate).to model_have_error_on_field(:ip)
    end

    it 'is invalid with a duplicate CIDR' do
      Fabricate(:ip_block, ip: '192.0.2.0/24', severity: :sign_up_block)
      duplicate = Fabricate.build(:ip_block, ip: '192.0.2.0/24', severity: :no_access)
      duplicate.valid?
      expect(duplicate).to model_have_error_on_field(:ip)
    end

    it 'is valid with a different IP' do
      Fabricate(:ip_block, ip: '192.0.2.1', severity: :sign_up_block)
      other = Fabricate.build(:ip_block, ip: '192.0.2.2', severity: :sign_up_block)
      expect(other).to be_valid
    end

    it 'is valid with a different CIDR prefix for the same network address' do
      Fabricate(:ip_block, ip: '192.0.2.0/24', severity: :sign_up_block)
      other = Fabricate.build(:ip_block, ip: '192.0.2.0/25', severity: :sign_up_block)
      expect(other).to be_valid
    end
  end

  describe '.blocked?' do
    it 'returns true for a no_access IP' do
      Fabricate(:ip_block, ip: '192.0.2.1', severity: :no_access)
      expect(described_class.blocked?('192.0.2.1')).to be true
    end

    it 'returns false for a sign_up_block IP' do
      Fabricate(:ip_block, ip: '192.0.2.1', severity: :sign_up_block)
      expect(described_class.blocked?('192.0.2.1')).to be false
    end

    it 'returns false for a sign_up_requires_approval IP' do
      Fabricate(:ip_block, ip: '192.0.2.1', severity: :sign_up_requires_approval)
      expect(described_class.blocked?('192.0.2.1')).to be false
    end
  end

  describe '#to_log_human_identifier' do
    it 'includes the prefix for an IPv4 host address' do
      ip_block = Fabricate(:ip_block, ip: '192.0.2.1', severity: :sign_up_block)
      expect(ip_block.to_log_human_identifier).to eq '192.0.2.1/32'
    end

    it 'includes the prefix for a CIDR block' do
      ip_block = Fabricate(:ip_block, ip: '192.0.2.0/24', severity: :sign_up_block)
      expect(ip_block.to_log_human_identifier).to eq '192.0.2.0/24'
    end
  end
end
