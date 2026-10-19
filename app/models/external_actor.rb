# frozen_string_literal: true

# == Schema Information
#
# Table name: external_actors
#
#  id                :bigint(8)        not null, primary key
#  protocol          :string           not null
#  native_id         :text             not null
#  handle            :string
#  display_name      :string
#  profile_url       :text
#  avatar_remote_url :text
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#
class ExternalActor < ApplicationRecord
  PROTOCOLS = %w(rss atom).freeze

  has_many :external_resources, dependent: :nullify

  validates :protocol, inclusion: { in: PROTOCOLS }
  validates :native_id, presence: true
end
