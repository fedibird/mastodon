// Internal Composer descriptor for a resolved Lemmy or PieFed discovery result.

const threadiverseGroupPostingContextFor = (software, accountId, acct) => {
  const id = String(accountId);

  return {
    key: `protocol:fep-1b12-${software}:${id}`,
    source: {
      id: `compat:${software}-group-note`,
      revision: 1,
    },
    managed: {
      hashtags: [],
      mentions: [
        {
          accountId: id,
          acct,
          enforcement: 'required',
          ruleId: `${software}-group-mention`,
          placement: 'append',
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
};

export const lemmyGroupPostingContextFor = (accountId, acct) => (
  threadiverseGroupPostingContextFor('lemmy', accountId, acct)
);

export const piefedGroupPostingContextFor = (accountId, acct) => (
  threadiverseGroupPostingContextFor('piefed', accountId, acct)
);

export const lemmyGroupPostingContext = lemmyGroupPostingContextFor('456', 'technology@lemmy.example');
export const piefedGroupPostingContext = piefedGroupPostingContextFor('456', 'technology@piefed.example');
