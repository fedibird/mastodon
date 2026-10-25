# frozen_string_literal: true

module EmojiReactionCapability
  # Status, author-account and viewer-relationship facts for one canonical
  # (status.proper) status. Plain values only; nothing here touches I/O.
  StatusContext = Data.define(
    :proper_status_id,
    :author_local,
    :author_domain,
    :author_silenced,
    :author_suspended,
    :author_activitypub,
    :external_projection,
    :status_override,
    :blocked_by_author,
    :viewer_blocks_author,
    :viewer_blocks_domain,
    :domain_rejected
  ) do
    def initialize(
      proper_status_id: nil,
      author_local: false,
      author_domain: nil,
      author_silenced: false,
      author_suspended: false,
      author_activitypub: true,
      external_projection: false,
      status_override: nil,
      blocked_by_author: false,
      viewer_blocks_author: false,
      viewer_blocks_domain: false,
      domain_rejected: false
    )
      super
    end
  end
end
