// Internal built-in Posting Context for a local Fedibird Group account.
// Not ActivityPub context and not the external Posting Context wire schema.
// Remote Group actors are not inferred here.

export function isFedibirdLocalGroup(account) {
  if (!account || typeof account.get !== 'function') {
    return false;
  }

  const acct = account.get('acct');
  const username = account.get('username');

  return account.get('group') === true && Boolean(acct) && acct === username;
}

export function buildFedibirdGroupPostingContext(account) {
  if (!isFedibirdLocalGroup(account)) {
    return null;
  }

  const accountId = account.get('id');
  const acct = account.get('acct');

  if (!accountId) {
    return null;
  }

  return {
    key: `builtin:fedibird-group:${accountId}`,

    source: {
      id: 'builtin:fedibird-group',
      revision: 1,
    },

    managed: {
      hashtags: [],
      mentions: [
        {
          accountId,
          acct,
          enforcement: 'required',
          ruleId: 'group-account-mention',
        },
      ],
    },

    requirements: {
      followingAccounts: [
        {
          accountId,
          acct,
          enforcement: 'required',
          ruleId: 'group-follow',
        },
      ],
    },

    constraints: {
      allowedVisibilities: [
        'public',
        'unlisted',
      ],
    },
  };
}
