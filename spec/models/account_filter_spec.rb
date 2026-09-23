require 'rails_helper'

describe AccountFilter do
  describe 'with empty params' do
    it 'defaults to recent local not-suspended account list' do
      filter = described_class.new({})

      expect(filter.results).to eq Account.local.without_instance_actor.recent.without_suspended
    end
  end

  describe 'with invalid params' do
    it 'raises with key error' do
      filter = described_class.new(wrong: true)

      expect { filter.results }.to raise_error(/wrong/)
    end
  end

  describe 'with valid params' do
    it 'combines filters on Account' do
      filter = described_class.new(
        by_domain: 'test.com',
        silenced: true,
        username: 'test',
        display_name: 'name',
        email: 'user@example.com',
      )

      allow(Account).to receive(:where).and_return(Account.none)
      allow(Account).to receive(:silenced).and_return(Account.none)
      allow(Account).to receive(:matches_display_name).and_return(Account.none)
      allow(Account).to receive(:matches_username).and_return(Account.none)
      allow(User).to receive(:matches_email).and_return(User.none)

      filter.results

      expect(Account).to have_received(:where).with(domain: 'test.com')
      expect(Account).to have_received(:silenced)
      expect(Account).to have_received(:matches_username).with('test')
      expect(Account).to have_received(:matches_display_name).with('name')
      expect(User).to have_received(:matches_email).with('user@example.com')
    end

    it 'keeps the legacy staff filter on moderator and admin booleans' do
      viewer = UserRole.create!(name: 'Viewer', position: 8, permissions_as_keys: %w(view_devops))
      legacy_moderator = Fabricate(:user, moderator: true)
      legacy_moderator.update_columns(role_id: viewer.id)
      reporter = UserRole.create!(name: 'Reporter', position: 9, permissions_as_keys: %w(manage_reports))
      custom = Fabricate(:user, admin: false, moderator: false)
      custom.update_columns(role_id: reporter.id)

      results = described_class.new(staff: '1').results

      expect(results).to include(legacy_moderator.account)
      expect(results).not_to include(custom.account)
    end

    it 'filters by role_ids without collapsing an array to a string' do
      custom = UserRole.create!(name: 'Filter role', position: 7, permissions_as_keys: %w(invite_users))
      matched = Fabricate(:user, admin: false, moderator: false)
      matched.update_columns(role_id: custom.id)
      other = Fabricate(:user, admin: true)

      results = described_class.new(role_ids: [custom.id.to_s]).results

      expect(results).to include(matched.account)
      expect(results).not_to include(other.account)
    end

    describe 'that call account methods' do
      %i(local remote silenced suspended).each do |option|
        it "delegates the #{option} option" do
          allow(Account).to receive(option).and_return(Account.none)
          filter = described_class.new({ option => true })
          filter.results

          expect(Account).to have_received(option).at_least(1)
        end
      end
    end
  end
end
