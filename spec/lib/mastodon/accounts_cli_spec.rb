# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/mastodon/accounts_cli')

# rubocop:disable Metrics/BlockLength
RSpec.describe Mastodon::AccountsCLI do
  before do
    load Rails.root.join('db/seeds/03_roles.rb')
    allow_any_instance_of(User).to receive(:send_devise_notification)
  end

  def invoke(command, arguments, **options)
    cli = described_class.new
    allow(cli).to receive(:say)
    allow(cli).to receive(:exit) { raise 'accounts CLI exited' }
    stdout = $stdout
    $stdout = StringIO.new
    cli.invoke(command, arguments, options)
  ensure
    $stdout = stdout
  end

  def role_named(name)
    UserRole.find_by!(name: name)
  end

  describe '#create' do
    def create_account(role)
      username = "cli_#{role}"
      invoke(:create, [username], email: "#{username}@example.com", role: role, skip_sign_in_token: true)
      Account.find_local(username).user
    end

    it 'stores --role user as Everyone without persisting the sentinel id' do
      user = create_account('user')

      expect(user.role_id).to be_nil
      expect(user.role_id).not_to eq(-99)
      expect(user.role.everyone?).to be true
      expect(user.admin).to be false
      expect(user.moderator).to be false
      expect(user.can?(:manage_users)).to be false
      expect(user.errors[:role_id]).to be_empty
    end

    it 'assigns Moderator and its runtime permissions' do
      user = create_account('moderator')

      expect(user.role_id).to eq(role_named('Moderator').id)
      expect(user.role.name).to eq('Moderator')
      expect(user.admin).to be false
      expect(user.moderator).to be false
      expect(user.can?(:manage_reports)).to be true
      expect(user.can?(:manage_settings)).to be false
    end

    it 'assigns Admin without devops permissions' do
      user = create_account('admin')

      expect(user.role_id).to eq(role_named('Admin').id)
      expect(user.role.name).to eq('Admin')
      expect(user.admin).to be false
      expect(user.moderator).to be false
      expect(user.can?(:manage_roles)).to be true
      expect(user.can?(:view_devops)).to be false
    end

    it 'assigns Owner and administrator permissions without legacy flags' do
      user = create_account('owner')

      expect(user.role_id).to eq(role_named('Owner').id)
      expect(user.role.name).to eq('Owner')
      expect(user.admin).to be false
      expect(user.moderator).to be false
      expect(user.can?(:manage_roles)).to be true
      expect(user.can?(:view_devops)).to be true
    end

    it 'fails when the requested default role is missing' do
      role_named('Owner').destroy!

      expect { create_account('owner') }.to raise_error(ActiveRecord::RecordNotFound, 'Failure/Error: required UserRole is missing')
      expect(Account.find_local('cli_owner')).to be_nil
    end
  end

  describe '#modify' do
    def modify_role(user, role)
      invoke(:modify, [user.account.username], role: role)
      user.reload
    end

    it 'sets moderator, admin, owner, and Everyone through role_id' do
      user = Fabricate(:user, admin: false, moderator: false)

      modify_role(user, 'moderator')
      expect(user.role_id).to eq(role_named('Moderator').id)
      expect(user.role.name).to eq('Moderator')
      expect(user.can?(:manage_reports)).to be true
      expect(user.can?(:manage_settings)).to be false

      modify_role(user, 'admin')
      expect(user.role_id).to eq(role_named('Admin').id)
      expect(user.role.name).to eq('Admin')
      expect(user.can?(:manage_roles)).to be true
      expect(user.can?(:view_devops)).to be false

      modify_role(user, 'owner')
      expect(user.role_id).to eq(role_named('Owner').id)
      expect(user.role.name).to eq('Owner')
      expect(user.admin).to be false
      expect(user.moderator).to be false
      expect(user.can?(:manage_roles)).to be true
      expect(user.can?(:view_devops)).to be true

      modify_role(user, 'user')
      expect(user.role_id).to be_nil
      expect(user.role_id).not_to eq(-99)
      expect(user.role.everyone?).to be true
      expect(user.can?(:manage_users)).to be false
    end

    it 'changes role_id and leaves a historical admin flag in place' do
      user = Fabricate(:user, admin: true, moderator: false)
      user.update_columns(role_id: nil)

      modify_role(user, 'moderator')

      expect(user.role_id).to eq(role_named('Moderator').id)
      expect(user.admin).to be true
      expect(user.moderator).to be false
      expect(user.can?(:manage_reports)).to be true
      expect(user.errors[:role_id]).to be_empty
    end

    it 'fails when the requested default role is missing' do
      user = Fabricate(:user, admin: false, moderator: false)
      role_named('Owner').destroy!

      expect { modify_role(user, 'owner') }.to raise_error(ActiveRecord::RecordNotFound, 'Failure/Error: required UserRole is missing')
      expect(user.reload.role_id).to be_nil
    end
  end
end
# rubocop:enable Metrics/BlockLength
