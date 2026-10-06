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
  };
}
