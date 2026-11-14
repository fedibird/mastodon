# frozen_string_literal: true

class ValidatePostDraftsPayloadCheck < ActiveRecord::Migration[6.1]
  # post_drafts is created empty by the stacked migrations and is not a
  # populated production table. VALIDATE runs in its own transaction so it
  # does not share the lock taken while the check was replaced. Ordinary
  # reads and writes are not blocked. Down leaves the check validated; the
  # previous migration's down is what restores the 32 KiB check, and that
  # down does not shrink rows already stored.
  def up
    validate_check_constraint :post_drafts, name: 'post_drafts_shape'
  end

  def down
    # no-op
  end
end
