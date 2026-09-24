require 'rails_helper'

RSpec.describe AccountsHelper, type: :helper do
  def set_not_embedded_view
    params[:controller] = "not_#{StatusesHelper::EMBEDDED_CONTROLLER}"
    params[:action] = "not_#{StatusesHelper::EMBEDDED_ACTION}"
  end

  def set_embedded_view
    params[:controller] = StatusesHelper::EMBEDDED_CONTROLLER
    params[:action] = StatusesHelper::EMBEDDED_ACTION
  end

  describe '#display_name' do
    it 'uses the display name when it exists' do
      account = Account.new(display_name: "Display", username: "Username")

      expect(helper.display_name(account)).to eq "Display"
    end

    it 'uses the username when display name is nil' do
      account = Account.new(display_name: nil, username: "Username")

      expect(helper.display_name(account)).to eq "Username"
    end
  end

  describe '#account_badge' do
    def account_for(role)
      user = Fabricate(:user, admin: false, moderator: false)
      user.update_columns(role_id: role.id)
      user.account
    end

    it 'hides Admin, Moderator, Owner, and a custom role when highlighted is false' do
      load Rails.root.join('db', 'seeds', '03_roles.rb')
      %w(Admin Moderator Owner).each do |name|
        role = UserRole.find_by!(name: name)
        role.update!(highlighted: false)
        expect(helper.account_badge(account_for(role))).to be_nil
      end

      custom = UserRole.create!(name: 'Quiet helper', permissions_as_keys: %w(manage_reports), highlighted: false)
      expect(helper.account_badge(account_for(custom))).to be_nil
    end

    it 'shows a highlighted custom role and still shows it only from highlighted' do
      custom = UserRole.create!(name: 'Visible helper', permissions_as_keys: %w(manage_reports), highlighted: true)

      expect(helper.account_badge(account_for(custom))).to include('Visible helper')
    end
  end

  describe '#acct' do
    it 'is fully qualified for embedded local accounts' do
      allow(Rails.configuration.x).to receive(:local_domain).and_return('local_domain')
      set_embedded_view
      account = Account.new(domain: nil, username: 'user')

      acct = helper.acct(account)

      expect(acct).to eq '@user@local_domain'
    end

    it 'is fully qualified for embedded foreign accounts' do
      set_embedded_view
      account = Account.new(domain: 'foreign_server.com', username: 'user')

      acct = helper.acct(account)

      expect(acct).to eq '@user@foreign_server.com'
    end

    it 'is fully qualified for non embedded foreign accounts' do
      set_not_embedded_view
      account = Account.new(domain: 'foreign_server.com', username: 'user')

      acct = helper.acct(account)

      expect(acct).to eq '@user@foreign_server.com'
    end

    it 'is fully qualified for non embedded local accounts' do
      allow(Rails.configuration.x).to receive(:local_domain).and_return('local_domain')
      set_not_embedded_view
      account = Account.new(domain: nil, username: 'user')

      acct = helper.acct(account)

      expect(acct).to eq '@user@local_domain'
    end
  end
end
