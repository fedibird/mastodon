import { normalizePostingContext, normalizePostingContextDiscovery } from '../normalize';

const restContext = {
  key: 'builtin:fedibird-group:123',
  source: {
    id: 'builtin:fedibird-group',
    revision: 1,
  },
  managed: {
    hashtags: [
      {
        name: 'News',
        normalized_name: 'news',
        enforcement: 'advisory',
        rule_id: 'hashtag-news',
      },
    ],
    mentions: [
      {
        account_id: '123',
        acct: 'group',
        enforcement: 'required',
        rule_id: 'group-account-mention',
      },
    ],
  },
  requirements: {
    following_accounts: [
      {
        account_id: '123',
        acct: 'group',
        enforcement: 'required',
        rule_id: 'group-follow',
      },
    ],
  },
  constraints: {
    allowed_visibilities: ['public', 'unlisted'],
  },
};

describe('normalizePostingContext', () => {
  it('converts a REST discovery context into the internal descriptor', () => {
    expect(normalizePostingContext(restContext)).toEqual({
      key: 'builtin:fedibird-group:123',
      source: {
        id: 'builtin:fedibird-group',
        revision: 1,
      },
      managed: {
        hashtags: [
          {
            name: 'News',
            normalizedName: 'news',
            enforcement: 'advisory',
            ruleId: 'hashtag-news',
          },
        ],
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
    });
  });

  it('returns null for a missing context', () => {
    expect(normalizePostingContext(null)).toBeNull();
  });
});

describe('normalizePostingContextDiscovery', () => {
  it('keeps context only when the result is resolved', () => {
    const resolved = normalizePostingContextDiscovery({
      schema_version: 1,
      account_id: '123',
      status: 'resolved',
      context: restContext,
      discovery: {
        mechanism: 'built_in',
        adapter: 'fedibird_group',
        authority: 'server',
      },
    });

    expect(resolved.status).toEqual('resolved');
    expect(resolved.accountId).toEqual('123');
    expect(resolved.reason).toBeNull();
    expect(resolved.context.managed.mentions[0].accountId).toEqual('123');
    expect(resolved.discovery).toEqual({
      mechanism: 'built_in',
      adapter: 'fedibird_group',
      authority: 'server',
    });

    const unsupported = normalizePostingContextDiscovery({
      schema_version: 1,
      account_id: '456',
      status: 'unsupported',
      reason: 'no_supported_adapter',
      context: restContext,
      discovery: {
        mechanism: null,
        adapter: null,
        authority: null,
      },
    });

    expect(unsupported.context).toBeNull();
    expect(unsupported.reason).toEqual('no_supported_adapter');
  });
});
