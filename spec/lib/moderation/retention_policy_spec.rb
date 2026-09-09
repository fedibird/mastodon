require 'rails_helper'

RSpec.describe Moderation::RetentionPolicy do
  describe '.retention_days' do
    it 'defaults to 365 when unset' do
      ClimateControl.modify MODERATION_LEDGER_RETENTION_DAYS: nil do
        expect(described_class.retention_days).to eq 365
      end
    end

    it 'reads MODERATION_LEDGER_RETENTION_DAYS' do
      ClimateControl.modify MODERATION_LEDGER_RETENTION_DAYS: '30' do
        expect(described_class.retention_days).to eq 30
      end
    end

    it 'clamps negative values to 0 (disabled)' do
      ClimateControl.modify MODERATION_LEDGER_RETENTION_DAYS: '-5' do
        expect(described_class.retention_days).to eq 0
        expect(described_class.enabled?).to be false
      end
    end
  end

  describe '.expire_at' do
    it 'is nil when retention is disabled' do
      ClimateControl.modify MODERATION_LEDGER_RETENTION_DAYS: '0' do
        expect(described_class.expire_at(Time.now.utc)).to be_nil
      end
    end

    it 'is the tombstone time plus the retention duration when enabled' do
      ClimateControl.modify MODERATION_LEDGER_RETENTION_DAYS: '10' do
        from = Time.utc(2026, 1, 1)
        expect(described_class.expire_at(from)).to eq(from + 10.days)
      end
    end
  end
end
