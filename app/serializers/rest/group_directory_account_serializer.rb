# frozen_string_literal: true

# Keep implementation metadata scoped to the group directory. The software name
# is the NodeInfo self-report, not proof of posting or moderation capabilities.
class REST::GroupDirectoryAccountSerializer < REST::AccountSerializer
  attribute :group_directory

  def group_directory
    {
      software: object.local? ? 'fedibird' : object.node&.software_name.presence&.downcase,
    }
  end
end
