// Internal Composer descriptor for a resolved NodeBB Group discovery result.
// The server adapter is covered by the Rails discovery spec.

export function nodebbGroupPostingContextFor(accountId, acct) {
  const id = String(accountId);

  return {
    key: `protocol:fep-1b12-nodebb:${id}`,
    source: {
      id: 'compat:nodebb-fep-1b12',
      revision: 1,
    },
    managed: {
      hashtags: [],
      mentions: [
        {
          accountId: id,
          acct,
          enforcement: 'required',
          ruleId: 'nodebb-group-mention',
        },
      ],
    },
    requirements: {
      followingAccounts: [],
    },
    constraints: {
      allowedVisibilities: ['public'],
    },
    protocol: {
      activityPub: {
        audience: {
          accountId: id,
          acct,
          enforcement: 'required',
          ruleId: 'fep-1b12-group-audience',
        },
      },
    },
  };
}

export const nodebbGroupPostingContext = nodebbGroupPostingContextFor('456', 'category@nodebb.example');
