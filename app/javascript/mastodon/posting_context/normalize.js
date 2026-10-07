// This normalizes Fedibird's REST discovery response into the internal
// Composer Posting Context descriptor.
//
// It is not the external Posting Context federation wire schema.

const normalizeManagedRecord = (record) => ({
  accountId: record.account_id,
  acct: record.acct,
  enforcement: record.enforcement,
  ruleId: record.rule_id,
});

const normalizeHashtag = (hashtag) => ({
  name: hashtag.name,
  normalizedName: hashtag.normalized_name,
  enforcement: hashtag.enforcement,
  ruleId: hashtag.rule_id,
});

const normalizeAudience = (audience) => {
  if (!audience) {
    return null;
  }

  return {
    accountId: audience.account_id,
    acct: audience.acct,
    enforcement: audience.enforcement,
    ruleId: audience.rule_id,
  };
};

const normalizeProtocol = (protocol) => {
  const activityPub = protocol && protocol.activitypub;

  return {
    activityPub: {
      audience: activityPub ? normalizeAudience(activityPub.audience) : null,
    },
  };
};

export function normalizePostingContext(context) {
  if (!context) {
    return null;
  }

  const hashtags = context.managed && context.managed.hashtags;
  const mentions = context.managed && context.managed.mentions;
  const followingAccounts = context.requirements && context.requirements.following_accounts;
  const allowedVisibilities = context.constraints ? context.constraints.allowed_visibilities : null;

  return {
    key: context.key,
    source: context.source ? {
      id: context.source.id,
      revision: context.source.revision,
    } : null,
    managed: {
      hashtags: (hashtags || []).map(normalizeHashtag),
      mentions: (mentions || []).map(normalizeManagedRecord),
    },
    requirements: {
      followingAccounts: (followingAccounts || []).map(normalizeManagedRecord),
    },
    constraints: {
      allowedVisibilities: allowedVisibilities || null,
    },
    protocol: normalizeProtocol(context.protocol),
  };
}

const normalizeAffiliationRelationship = (relationship) => ({
  relationship: relationship.relationship,
  affiliationUri: relationship.affiliation_uri || null,
});

export function normalizeViewerEvidence(evidence) {
  if (!evidence || !evidence.affiliations) {
    return null;
  }

  const affiliations = evidence.affiliations;

  return {
    affiliations: {
      source: affiliations.source,
      snapshotStatus: affiliations.snapshot_status,
      fetchedAt: affiliations.fetched_at || null,
      relationships: (affiliations.relationships || []).map(normalizeAffiliationRelationship),
    },
  };
}

export function normalizePostingContextDiscovery(data) {
  if (!data) {
    return null;
  }

  return {
    schemaVersion: data.schema_version,
    accountId: data.account_id,
    status: data.status,
    reason: data.reason || null,
    context: data.status === 'resolved' ? normalizePostingContext(data.context) : null,
    discovery: data.discovery ? {
      mechanism: data.discovery.mechanism,
      adapter: data.discovery.adapter,
      authority: data.discovery.authority,
    } : {
      mechanism: null,
      adapter: null,
      authority: null,
    },
    viewerEvidence: normalizeViewerEvidence(data.viewer_evidence),
  };
}
