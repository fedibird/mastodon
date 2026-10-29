# frozen_string_literal: true

# == Schema Information
#
# Table name: external_resources
#
#  id                           :bigint(8)        not null, primary key
#  external_source_id           :bigint(8)        not null
#  external_actor_id            :bigint(8)
#  protocol                     :string           not null
#  canonical_key                :text             not null
#  revision                     :text
#  canonical_url                :text
#  title                        :text
#  body                         :text
#  byline                       :text
#  author_hints                 :jsonb            not null
#  body_digest                  :string
#  published_at                 :datetime
#  source_deleted_at            :datetime
#  truncated                    :boolean          default(FALSE), not null
#  fetched_at                   :datetime
#  created_at                   :datetime         not null
#  updated_at                   :datetime         not null
#  media_revision               :text
#  media_candidates             :jsonb            not null
#  keywords                     :jsonb            not null
#  activitypub_state            :string           default("unknown"), not null
#  activitypub_candidate_url    :text
#  activitypub_candidate_digest :string(64)
#  activitypub_explicit         :boolean          default(FALSE), not null
#  activitypub_evidence_version :bigint(8)        default(0), not null
#  activitypub_object_id        :text
#  activitypub_object_id_status :string
#  activitypub_object_type      :string
#  activitypub_checked_at       :datetime
#  activitypub_next_check_at    :datetime
#
class ExternalResource < ApplicationRecord
  PROTOCOLS = %w(rss atom).freeze
  # activitypub_state "verified" means the candidate URL returned an
  # ActivityStreams 2.0 object. It does not mean activitypub_object_id was
  # dereferenced. That id is self-reported when object_id_status says so.
  OBJECT_ID_SELF_REPORTED = 'self_reported'
  ACTIVITYPUB_DUE_AT = Time.utc(1970, 1, 1).freeze

  def self.digest_activitypub_candidate(url)
    return nil if url.blank?

    Digest::SHA256.hexdigest(url)
  end

  belongs_to :external_source
  belongs_to :external_actor, optional: true
  has_many :external_status_projections, dependent: :restrict_with_exception

  validates :protocol, inclusion: { in: PROTOCOLS }
  validates :canonical_key, presence: true

  before_create :prepare_activitypub_candidate

  private

  # Rows created outside the feed writer still get a digest and a due time,
  # so the probe claim can match them. update_all from the probe does not
  # come through here.
  def prepare_activitypub_candidate
    return if activitypub_candidate_url.blank?

    self.activitypub_candidate_digest ||= self.class.digest_activitypub_candidate(activitypub_candidate_url)
    self.activitypub_next_check_at ||= ACTIVITYPUB_DUE_AT
  end
end
