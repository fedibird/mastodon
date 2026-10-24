# frozen_string_literal: true

# == Schema Information
#
# Table name: external_projection_link_boost_states
#
#  user_id              :bigint(8)        not null, primary key
#  projection_status_id :bigint(8)        not null, primary key
#  revision             :bigint(8)        not null
#  notified_revision    :bigint(8)        default(0), not null
#  reblogged            :boolean          not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#

# The monotonic (revision, reblogged) pair of one projection for one User.
# Written only by the external_projection_link_boosts_track_state trigger.
# Application code reads it, marks `notified_revision` after an owner event was
# published, and deletes it on purge. A pair with no row
# means revision 0, reblogged false.
class ExternalProjectionLinkBoostState < ApplicationRecord
  self.primary_key = nil

  belongs_to :user
end
