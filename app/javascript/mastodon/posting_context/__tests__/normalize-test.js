import { normalizePostingContext, normalizePostingContextDiscovery, normalizeViewerEvidence } from '../normalize';

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
            placement: 'prepend',
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
      protocol: {
        activityPub: {
          audience: null,
        },
      },
    });
  });

  it('converts an ActivityPub audience target and leaves older payloads without one', () => {
    const withAudience = normalizePostingContext({
      ...restContext,
      protocol: {
        activitypub: {
          audience: {
            account_id: '456',
            acct: 'group@example.com',
            enforcement: 'required',
            rule_id: 'fep-1b12-group-audience',
          },
        },
      },
    });

    expect(withAudience.protocol).toEqual({
      activityPub: {
        audience: {
          accountId: '456',
          acct: 'group@example.com',
          enforcement: 'required',
          ruleId: 'fep-1b12-group-audience',
        },
      },
    });
    expect(withAudience.managed.mentions[0].acct).toEqual('group');

    const legacy = normalizePostingContext({
      key: 'builtin:hashtag:news',
      managed: { hashtags: [], mentions: [] },
      requirements: { following_accounts: [] },
      constraints: {},
    });

    expect(legacy.protocol).toEqual({
      activityPub: {
        audience: null,
      },
    });
    expect(legacy.managed.mentions).toEqual([]);
  });

  it('normalizes a Mitra group discovery payload into an audience target', () => {
    const normalized = normalizePostingContextDiscovery({
      schema_version: 1,
      account_id: '456',
      status: 'resolved',
      context: {
        key: 'protocol:fep-1b12-group:456',
        source: { id: 'compat:mitra-fep-1b12', revision: 1 },
        managed: { hashtags: [], mentions: [] },
        requirements: { following_accounts: [] },
        constraints: { allowed_visibilities: ['public', 'unlisted'] },
        protocol: {
          activitypub: {
            audience: {
              account_id: '456',
              acct: 'group@mitra.example',
              enforcement: 'required',
              rule_id: 'fep-1b12-group-audience',
            },
          },
        },
      },
      discovery: {
        mechanism: 'nodeinfo_software',
        adapter: 'mitra_group',
        authority: 'compatibility',
      },
    });

    expect(normalized.schemaVersion).toEqual(1);
    expect(normalized.status).toEqual('resolved');
    expect(normalized.discovery).toEqual({
      mechanism: 'nodeinfo_software',
      adapter: 'mitra_group',
      authority: 'compatibility',
    });
    expect(normalized.context.managed.mentions).toEqual([]);
    expect(normalized.context.requirements.followingAccounts).toEqual([]);
    expect(normalized.context.constraints.allowedVisibilities).toEqual(['public', 'unlisted']);
    expect(normalized.context.protocol).toEqual({
      activityPub: {
        audience: {
          accountId: '456',
          acct: 'group@mitra.example',
          enforcement: 'required',
          ruleId: 'fep-1b12-group-audience',
        },
      },
    });
  });

  it('normalizes a NodeBB group discovery payload with a required mention and public-only constraint', () => {
    const normalized = normalizePostingContextDiscovery({
      schema_version: 1,
      account_id: '456',
      status: 'resolved',
      context: {
        key: 'protocol:fep-1b12-nodebb:456',
        source: { id: 'compat:nodebb-fep-1b12', revision: 1 },
        managed: {
          hashtags: [],
          mentions: [
            {
              account_id: '456',
              acct: 'category@nodebb.example',
              enforcement: 'required',
              rule_id: 'nodebb-group-mention',
            },
          ],
        },
        requirements: { following_accounts: [] },
        constraints: { allowed_visibilities: ['public'] },
        protocol: {
          activitypub: {
            audience: {
              account_id: '456',
              acct: 'category@nodebb.example',
              enforcement: 'required',
              rule_id: 'fep-1b12-group-audience',
            },
          },
        },
      },
      discovery: {
        mechanism: 'nodeinfo_software',
        adapter: 'nodebb_group',
        authority: 'compatibility',
      },
      viewer_evidence: {
        affiliations: {
          source: 'fep-5219-affiliations',
          snapshot_status: 'fresh',
          fetched_at: '2026-10-08T00:00:00Z',
          relationships: [],
        },
        permissions: {
          create: {
            status: 'unknown',
            source: 'fep-5219',
            via_relationship: null,
            authority: 'protocol',
          },
        },
      },
    });

    expect(normalized.discovery.adapter).toEqual('nodebb_group');
    expect(normalized.discovery.authority).toEqual('compatibility');
    expect(normalized.context.constraints.allowedVisibilities).toEqual(['public']);
    expect(normalized.context.managed.mentions[0].acct).toEqual('category@nodebb.example');
    expect(normalized.context.protocol.activityPub.audience.accountId).toEqual('456');
    expect(normalized.viewerEvidence.permissions.create.status).toEqual('unknown');
  });

  it('keeps Lemmy after_title and PieFed append placements, and treats an omitted placement as prepend', () => {
    const lemmy = normalizePostingContext({
      key: 'protocol:fep-1b12-lemmy:456',
      source: { id: 'compat:lemmy-group-note', revision: 1 },
      managed: {
        hashtags: [],
        mentions: [
          {
            account_id: '456',
            acct: 'technology@lemmy.example',
            enforcement: 'required',
            rule_id: 'lemmy-group-mention',
            placement: 'after_title',
          },
        ],
      },
      requirements: { following_accounts: [] },
      constraints: { allowed_visibilities: ['public'] },
      protocol: {
        activitypub: {
          audience: {
            account_id: '456',
            acct: 'technology@lemmy.example',
            enforcement: 'required',
            rule_id: 'fep-1b12-group-audience',
          },
        },
      },
    });
    const piefed = normalizePostingContext({
      key: 'protocol:fep-1b12-piefed:456',
      source: { id: 'compat:piefed-group-note', revision: 1 },
      managed: {
        hashtags: [],
        mentions: [
          {
            account_id: '456',
            acct: 'technology@piefed.example',
            enforcement: 'required',
            rule_id: 'piefed-group-mention',
            placement: 'append',
          },
        ],
      },
      requirements: { following_accounts: [] },
      constraints: { allowed_visibilities: ['public'] },
      protocol: {
        activitypub: {
          audience: {
            account_id: '456',
            acct: 'technology@piefed.example',
            enforcement: 'required',
            rule_id: 'fep-1b12-group-audience',
          },
        },
      },
    });
    const omitted = normalizePostingContext(restContext);
    const unknown = normalizePostingContext({
      ...restContext,
      managed: {
        ...restContext.managed,
        mentions: [
          {
            ...restContext.managed.mentions[0],
            placement: 'beside',
          },
        ],
      },
    });

    expect(lemmy.managed.mentions[0].placement).toEqual('after_title');
    expect(piefed.managed.mentions[0].placement).toEqual('append');
    expect(lemmy.constraints.allowedVisibilities).toEqual(['public']);
    expect(omitted.managed.mentions[0].placement).toEqual('prepend');
    expect(unknown.managed.mentions[0].placement).toEqual('prepend');
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
    expect(resolved.viewerEvidence).toBeNull();

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
    expect(unsupported.viewerEvidence).toBeNull();
  });

  it('normalizes fresh viewer affiliation evidence and leaves older payloads without it', () => {
    expect(normalizeViewerEvidence(null)).toBeNull();
    expect(normalizePostingContextDiscovery({
      schema_version: 1,
      account_id: '456',
      status: 'unsupported',
      reason: 'no_supported_adapter',
      context: null,
      discovery: { mechanism: null, adapter: null, authority: null },
    }).viewerEvidence).toBeNull();

    const normalized = normalizeViewerEvidence({
      affiliations: {
        source: 'fep-5219-affiliations',
        snapshot_status: 'fresh',
        fetched_at: '2026-10-07T01:23:45Z',
        relationships: [
          { relationship: 'admin', affiliation_uri: 'https://mitra.example/relationships/1' },
          { relationship: 'trusted-poster', affiliation_uri: null },
        ],
      },
    });

    expect(normalized).toEqual({
      affiliations: {
        source: 'fep-5219-affiliations',
        snapshotStatus: 'fresh',
        fetchedAt: '2026-10-07T01:23:45Z',
        relationships: [
          { relationship: 'admin', affiliationUri: 'https://mitra.example/relationships/1' },
          { relationship: 'trusted-poster', affiliationUri: null },
        ],
      },
      permissions: null,
    });
  });

  it('normalizes create permission evidence and leaves it null when absent', () => {
    const allowed = normalizeViewerEvidence({
      affiliations: {
        source: 'fep-5219-affiliations',
        snapshot_status: 'fresh',
        fetched_at: '2026-10-07T01:23:45Z',
        relationships: [
          { relationship: 'admin', affiliation_uri: 'https://mitra.example/relationships/1' },
        ],
      },
      permissions: {
        create: {
          status: 'allowed',
          source: 'fep-5219',
          via_relationship: 'admin',
          authority: 'protocol',
        },
      },
    });

    expect(allowed.permissions).toEqual({
      create: {
        status: 'allowed',
        source: 'fep-5219',
        viaRelationship: 'admin',
        authority: 'protocol',
      },
    });

    const unknown = normalizeViewerEvidence({
      affiliations: {
        source: 'fep-5219-affiliations',
        snapshot_status: 'fresh',
        fetched_at: '2026-10-07T01:23:45Z',
        relationships: [],
      },
      permissions: {
        create: {
          status: 'unknown',
          source: 'fep-5219',
          via_relationship: null,
          authority: 'protocol',
        },
      },
    });

    expect(unknown.permissions.create).toEqual({
      status: 'unknown',
      source: 'fep-5219',
      viaRelationship: null,
      authority: 'protocol',
    });
    expect(unknown.permissions.view).toBeUndefined();
  });

  it('normalizes view permission evidence beside create', () => {
    const normalized = normalizeViewerEvidence({
      affiliations: {
        source: 'fep-5219-affiliations',
        snapshot_status: 'fresh',
        fetched_at: '2026-10-07T01:23:45Z',
        relationships: [
          { relationship: 'trusted-poster', affiliation_uri: null },
        ],
      },
      permissions: {
        create: {
          status: 'allowed',
          source: 'fep-5219',
          via_relationship: 'trusted-poster',
          authority: 'protocol',
        },
        view: {
          status: 'unknown',
          source: 'fep-5219',
          via_relationship: null,
          authority: 'protocol',
        },
      },
    });

    expect(normalized.permissions.create.viaRelationship).toEqual('trusted-poster');
    expect(normalized.permissions.view).toEqual({
      status: 'unknown',
      source: 'fep-5219',
      viaRelationship: null,
      authority: 'protocol',
    });
    expect(normalized.affiliations.fetchedAt).toEqual('2026-10-07T01:23:45Z');
  });
});
