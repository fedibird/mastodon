# frozen_string_literal: true

class PostingContext::GroupAffiliationEvidenceResolver
  SOURCE = 'fep-5219-affiliations'
  FRESH_FOR = 1.day

  # Relationship labels are evidence, not permissions. A fresh empty list
  # means this snapshot has no positive affiliation for the viewer. It is
  # not a posting denial, and stale rows are not returned as evidence.
  def call(group_account, viewer_account)
    return unavailable_result unless viewer_account && group_account&.group?

    status = snapshot_status(group_account)

    {
      source: SOURCE,
      snapshot_status: status,
      fetched_at: iso8601(group_account.affiliations_fetched_at),
      relationships: status == 'fresh' ? relationships_for(group_account, viewer_account) : [],
    }
  end

  private

  def snapshot_status(group_account)
    fetched_at = group_account.affiliations_fetched_at
    return freshness(fetched_at) if fetched_at.present?
    return 'unfetched' if group_account.affiliations_url.present?

    'unavailable'
  end

  def freshness(fetched_at)
    fetched_at > FRESH_FOR.ago ? 'fresh' : 'stale'
  end

  def relationships_for(group_account, viewer_account)
    subject_uri = ActivityPub::TagManager.instance.uri_for(viewer_account)
    return [] if subject_uri.blank?

    group_account.group_affiliations.where(subject_uri: subject_uri).sort_by { |row| [row.relationship, row.affiliation_uri.to_s] }.map do |row|
      {
        relationship: row.relationship,
        affiliation_uri: row.affiliation_uri,
      }
    end
  end

  def iso8601(timestamp)
    timestamp&.utc&.iso8601
  end

  def unavailable_result
    {
      source: SOURCE,
      snapshot_status: 'unavailable',
      fetched_at: nil,
      relationships: [],
    }
  end
end
