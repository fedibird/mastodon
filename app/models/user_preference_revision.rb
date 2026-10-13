# frozen_string_literal: true

class UserPreferenceRevision < ApplicationRecord
  self.primary_key = :user_id

  belongs_to :user
end
