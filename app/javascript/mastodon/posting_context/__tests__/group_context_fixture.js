// Generic Composer descriptor used by tests.
// Fedibird Group discovery itself is covered by the Rails service spec.

export const groupPostingContext = {
  key: 'builtin:fedibird-group:123',
  source: {
    id: 'builtin:fedibird-group',
    revision: 1,
  },
  managed: {
    hashtags: [],
    mentions: [
      {
        accountId: '123',
        acct: 'group',
        enforcement: 'required',
        ruleId: 'group-account-mention',
      },
    ],
  },
  requirements: {
    followingAccounts: [
      {
        accountId: '123',
        acct: 'group',
        enforcement: 'required',
        ruleId: 'group-follow',
      },
    ],
  },
  constraints: {
    allowedVisibilities: ['public', 'unlisted'],
  },
};
