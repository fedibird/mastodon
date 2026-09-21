# frozen_string_literal: true

# Generic human-approval foundation for operations that may need review
# before execution. Not a Follow Import-specific feature and not a
# moderation-evidence namespace: some reviewed operations (invite
# creation, migration) are administrative approval, not abuse verdicts.
#
# This layer stores policy + audit snapshots only. It does not block,
# approve, release, reject, or execute any user operation yet.
module ActionReview
end
