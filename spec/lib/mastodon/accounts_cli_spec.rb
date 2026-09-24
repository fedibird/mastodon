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
    @cli = described_class.new
    stdout = $stdout
    @output = StringIO.new
    $stdout = @output
    @cli.invoke(command, arguments, options)
    @cli
  ensure
    $stdout = stdout
  end

  def role_named(name)
    UserRole.find_by!(name: name)
  end

  describe '#create' do
    def create_account(username, **options)
      invoke(:create, [username], email: "#{username}@example.com", skip_sign_in_token: true, **options)
      Account.find_local(username)&.user
    end

    it 'leaves role_id nil when --role is omitted' do
      user = create_account('cli_plain')

      expect(user.role_id).to be_nil
      expect(user.role_id).not_to eq(-99)
      expect(user.role.everyone?).to be true
      expect(user.admin).to be false
      expect(user.moderator).to be false
      expect(user.can?(:manage_users)).to be false
    end

    it 'assigns a role by its stored name' do
      user = create_account('cli_moderator', role: 'Moderator')

      expect(user.role_id).to eq(role_named('Moderator').id)
      expect(user.role.name).to eq('Moderator')
      expect(user.admin).to be false
      expect(user.moderator).to be false
      expect(user.can?(:manage_reports)).to be true
      expect(user.can?(:manage_settings)).to be false
    end

    it 'assigns Admin by name without devops permissions' do
      user = create_account('cli_admin', role: 'Admin')

      expect(user.role_id).to eq(role_named('Admin').id)
      expect(user.role.name).to eq('Admin')
      expect(user.can?(:manage_roles)).to be true
      expect(user.can?(:view_devops)).to be false
      expect(user.admin).to be false
      expect(user.moderator).to be false
    end

    it 'assigns Owner by name and grants administrator permissions' do
      user = create_account('cli_owner', role: 'Owner')

      expect(user.role_id).to eq(role_named('Owner').id)
      expect(user.role.name).to eq('Owner')
      expect(user.admin).to be false
      expect(user.moderator).to be false
      expect(user.can?(:manage_roles)).to be true
      expect(user.can?(:view_devops)).to be true
    end

    it 'assigns a custom role by name' do
      custom = UserRole.create!(name: 'Cli custom', position: 40, permissions_as_keys: %w(manage_reports))
      user = create_account('cli_custom', role: 'Cli custom')

      expect(user.role_id).to eq(custom.id)
      expect(user.role.name).to eq('Cli custom')
      expect(user.admin).to be false
      expect(user.moderator).to be false
      expect(user.can?(:manage_reports)).to be true
      expect(user.can?(:manage_settings)).to be false
    end

    it 'fails before saving when the role name does not exist' do
      expect { create_account('cli_missing', role: 'Not a role') }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
      expect(@output.string).to include('Cannot find user role with that name')
      expect(Account.find_local('cli_missing')).to be_nil
    end
  end

  describe '#modify' do
    it 'assigns Moderator, Admin, Owner, and a custom role by name' do
      user = Fabricate(:user, admin: false, moderator: false)
      custom = UserRole.create!(name: 'Modify custom', position: 41, permissions_as_keys: %w(manage_reports))

      invoke(:modify, [user.account.username], role: 'Moderator')
      user.reload
      expect(user.role_id).to eq(role_named('Moderator').id)
      expect(user.can?(:manage_reports)).to be true
      expect(user.can?(:manage_settings)).to be false

      invoke(:modify, [user.account.username], role: 'Admin')
      user.reload
      expect(user.role_id).to eq(role_named('Admin').id)
      expect(user.can?(:manage_roles)).to be true
      expect(user.can?(:view_devops)).to be false

      invoke(:modify, [user.account.username], role: 'Owner')
      user.reload
      expect(user.role_id).to eq(role_named('Owner').id)
      expect(user.role.name).to eq('Owner')
      expect(user.admin).to be false
      expect(user.moderator).to be false
      expect(user.can?(:manage_roles)).to be true
      expect(user.can?(:view_devops)).to be true

      invoke(:modify, [user.account.username], role: 'Modify custom')
      user.reload
      expect(user.role_id).to eq(custom.id)
      expect(user.can?(:manage_reports)).to be true
    end

    it 'clears role_id with --remove-role and leaves legacy flags unchanged' do
      user = Fabricate(:user, admin: true, moderator: false)
      user.update_columns(role_id: role_named('Owner').id)

      invoke(:modify, [user.account.username], remove_role: true)
      user.reload

      expect(user.role_id).to be_nil
      expect(user.role_id).not_to eq(-99)
      expect(user.role.everyone?).to be true
      expect(user.admin).to be true
      expect(user.moderator).to be false
      expect(user.can?(:manage_users)).to be false
    end

    it 'changes role_id and leaves a historical admin flag in place' do
      user = Fabricate(:user, admin: true, moderator: false)
      user.update_columns(role_id: nil)

      invoke(:modify, [user.account.username], role: 'Moderator')
      user.reload

      expect(user.role_id).to eq(role_named('Moderator').id)
      expect(user.admin).to be true
      expect(user.moderator).to be false
      expect(user.can?(:manage_reports)).to be true
    end

    it 'fails before saving when the role name does not exist' do
      user = Fabricate(:user, admin: true, moderator: true)
      user.update_columns(role_id: role_named('Admin').id)

      expect { invoke(:modify, [user.account.username], role: 'Not a role') }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
      expect(@output.string).to include('Cannot find user role with that name')

      user.reload
      expect(user.role_id).to eq(role_named('Admin').id)
      expect(user.admin).to be true
      expect(user.moderator).to be true
    end
  end

  describe '#legacy_admin_roles' do
    it 'reports candidates and does not reverse an explicit Admin or Owner choice' do
      explicit_admin = Fabricate(:user, admin: true, moderator: false)
      explicit_owner = Fabricate(:user, admin: true, moderator: false)
      custom_role = UserRole.create!(name: 'Kept', permissions_as_keys: %w(manage_reports))
      custom = Fabricate(:user, admin: true, moderator: false)
      explicit_admin.update_columns(role_id: role_named('Admin').id)
      explicit_owner.update_columns(role_id: role_named('Owner').id)
      custom.update_columns(role_id: custom_role.id)
      owner_count = User.where(admin: true, role_id: role_named('Owner').id).count
      admin_count = User.where(admin: true, role_id: role_named('Admin').id).count

      invoke(:legacy_admin_roles, [])

      expect(explicit_admin.reload.role_id).to eq role_named('Admin').id
      expect(explicit_owner.reload.role_id).to eq role_named('Owner').id
      expect(custom.reload.role_id).to eq custom_role.id
      expect(@output.string).to include('No roles were changed')
      expect(@output.string).to include("Owner: #{owner_count}")
      expect(@output.string).to include("Admin: #{admin_count}")
    end

    it 'moves only Owner and unset legacy admins to Admin when opted in' do
      owner = Fabricate(:user, admin: true, moderator: false)
      unset = Fabricate(:user, admin: true, moderator: false)
      explicit_admin = Fabricate(:user, admin: true, moderator: false)
      custom_role = UserRole.create!(name: 'Kept opt-in', permissions_as_keys: %w(manage_reports))
      custom = Fabricate(:user, admin: true, moderator: false)
      owner.update_columns(role_id: role_named('Owner').id, updated_at: 2.days.ago)
      unset.update_columns(role_id: nil)
      explicit_admin.update_columns(role_id: role_named('Admin').id)
      custom.update_columns(role_id: custom_role.id)
      stamped = owner.reload.updated_at

      invoke(:legacy_admin_roles, [], reassign_to_admin: true)

      expect(owner.reload.role_id).to eq role_named('Admin').id
      expect(owner.updated_at).to be_within(1.second).of(stamped)
      expect(unset.reload.role_id).to eq role_named('Admin').id
      expect(explicit_admin.reload.role_id).to eq role_named('Admin').id
      expect(custom.reload.role_id).to eq custom_role.id
    end
  end
end
# rubocop:enable Metrics/BlockLength
