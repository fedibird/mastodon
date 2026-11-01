# frozen_string_literal: true

# Account JSON plus the directory fields this screen needs.
# group_directory is not added to the shared account serializer.
#
# software is the NodeInfo self-report (local rows are fedibird). It is not
# evidence that anyone can post. languages is explicit group metadata only;
# an empty list means unset, not "every language". capabilities.posting stays
# null until a Group Capability Resolver confirms the viewer's relationship
# and the group's public rules. Do not fill it from software or from the
# built-in posting-context adapter.
class REST::GroupDirectoryAccountSerializer < REST::AccountSerializer
  attribute :group_directory

  def group_directory
    {
      software: directory_software,
      languages: directory_languages,
      capabilities: {
        posting: nil,
      },
    }
  end

  private

  def directory_software
    return 'fedibird' if object.local?

    object.node&.software_name.to_s.strip.downcase.presence
  end

  # Empty means the group has not declared a language. Do not infer one.
  def directory_languages
    tags = if object.association(:group_languages).loaded?
             object.group_languages.map(&:tag)
           else
             object.group_languages.pluck(:tag)
           end
    tags.sort
  end
end
