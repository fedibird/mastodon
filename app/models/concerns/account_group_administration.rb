# frozen_string_literal: true

# Local group administration links. Including this does not create rows,
# copy followers, or change delivery.
module AccountGroupAdministration
  extend ActiveSupport::Concern

  included do
    has_many :group_creation_requests,
             foreign_key: :requester_account_id,
             inverse_of: :requester_account
    has_one :managed_group,
            foreign_key: :account_id,
            inverse_of: :account
    has_many :group_role_assignments,
             foreign_key: :group_account_id,
             inverse_of: :group_account
    has_many :held_group_roles,
             class_name: 'GroupRoleAssignment',
             foreign_key: :member_account_id,
             inverse_of: :member_account
  end
end
