// Internal Composer descriptor for a resolved Mitra Group discovery result.
// The server adapter is covered by the Rails discovery spec. This fixture
// is the normalized shape the WebUI already understands.

export const mitraGroupPostingContext = {
  key: 'protocol:fep-1b12-group:456',
  source: {
    id: 'compat:mitra-fep-1b12',
    revision: 1,
  },
  managed: {
    hashtags: [],
    mentions: [],
  },
  requirements: {
    followingAccounts: [],
  },
  constraints: {
    allowedVisibilities: ['public', 'unlisted'],
  },
  protocol: {
    activityPub: {
      audience: {
        accountId: '456',
        acct: 'group@mitra.example',
        enforcement: 'required',
        ruleId: 'fep-1b12-group-audience',
      },
    },
  },
};
