# frozen_string_literal: true

# == Schema Information
#
# Table name: reboost_count_releases
#
#  status_id  :bigint(8)        not null, primary key
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
class ReboostCountRelease < ApplicationRecord
  self.primary_key = 'status_id'
end
