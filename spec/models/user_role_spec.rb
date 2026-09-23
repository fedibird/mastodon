# frozen_string_literal: true

require 'rails_helper'

RSpec.describe UserRole, type: :model do # rubocop:disable Metrics/BlockLength
  describe 'permission flags' do
    it 'keeps the Mastodon 4.2 bitmask' do
      expect(described_class::FLAGS[:administrator]).to eq(1 << 0)
      expect(described_class::FLAGS[:invite_users]).to eq(1 << 16)
      expect(described_class::FLAGS[:delete_user_data]).to eq(1 << 19)
      expect(described_class::Flags::NONE).to eq 0
      expect(described_class::Flags::ALL).to eq described_class::FLAGS.values.reduce(:|)
      expect(described_class::Flags::DEFAULT).to eq described_class::FLAGS[:invite_users]
    end

    it 'round-trips permissions_as_keys' do
      keys = %w(manage_reports manage_blocks)
      role = described_class.new(name: 'Custom', permissions_as_keys: keys)

      expect(role.permissions).to eq(described_class::FLAGS[:manage_reports] | described_class::FLAGS[:manage_blocks])
      expect(role.permissions_as_keys).to match_array(keys)

      role.permissions_as_keys = %w(manage_blocks manage_reports unknown)
      expect(role.permissions_as_keys).to match_array(keys)
    end

    it 'treats administrator as every permission' do
      described_class.everyone
      role = described_class.create!(name: 'Root', permissions_as_keys: %w(administrator))

      expect(role.computed_permissions).to eq described_class::Flags::ALL
      expect(role.can?(:administrator)).to be true
      expect(role.can?(:delete_user_data)).to be true
      expect(role.can?(:manage_webhooks)).to be true
    end
  end

  describe '.everyone' do
    it 'uses the reserved id and the invite_users default' do
      described_class.where(id: -99).delete_all
      role = described_class.everyone

      expect(role.id).to eq(-99)
      expect(role.position).to eq(-1)
      expect(role.permissions).to eq described_class::Flags::DEFAULT
      expect(role.can?(:invite_users)).to be true
      expect(role.can?(:manage_users)).to be false
      expect(described_class.where(id: -99).count).to eq 1
    end
  end

  describe '.nobody' do
    it 'grants no permissions' do
      role = described_class.nobody

      expect(role).to be_nobody
      expect(role.position).to eq(-1)
      expect(role.computed_permissions).to eq described_class::Flags::NONE
      expect(role.can?(:invite_users)).to be false
      expect(role.can?(:administrator)).to be false
    end
  end

  describe '#overrides?' do
    it 'follows position, with a missing role always overridden' do
      moderator = described_class.new(name: 'Moderator', position: 10)
      admin     = described_class.new(name: 'Admin', position: 100)
      owner     = described_class.new(name: 'Owner', position: 1000)

      expect(owner.overrides?(admin)).to be true
      expect(admin.overrides?(moderator)).to be true
      expect(moderator.overrides?(owner)).to be false
      expect(moderator.overrides?(nil)).to be true
    end
  end
end
