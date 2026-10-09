import { resolveSenderIdentitySwitch } from '../switch_resolver';

const ready = (id, extra = {}) => ({
  id,
  kind: 'local',
  provider: 'fedibird',
  authorization: 'ready',
  capabilities: {
    post: 'supported',
    media: 'supported',
    reply: 'supported',
    group: 'supported',
    schedule: 'supported',
  },
  registered: true,
  ...extra,
});

const draft = (extra = {}) => ({
  text: 'Keep this draft',
  senderStatus: 'ready',
  media: [],
  idempotencyKey: 'key-before',
  userPostingContext: { privacy: 'private' },
  manual: { privacy: 'unlisted' },
  postingContext: { locks: { privacy: 'public' } },
  ...extra,
});

describe('resolveSenderIdentitySwitch', () => {
  it('keeps text and rotates the idempotency key only when the sender changes', () => {
    const same = resolveSenderIdentitySwitch({
      fromIdentityId: 'local:42',
      toIdentity: ready('local:42'),
      sessionIdentityId: 'local:42',
      draft: draft(),
      nextIdempotencyKey: 'key-next',
    });

    expect(same.permitted).toBe(true);
    expect(same.changing).toBe(false);
    expect(same.preserveText).toBe(true);
    expect(same.preservedText).toEqual('Keep this draft');
    expect(same.rotateIdempotencyKey).toBe(false);
    expect(same.nextIdempotencyKey).toEqual('key-before');

    const moved = resolveSenderIdentitySwitch({
      fromIdentityId: 'local:7',
      toIdentity: ready('local:42'),
      sessionIdentityId: 'local:42',
      draft: draft(),
      nextIdempotencyKey: 'key-next',
    });

    expect(moved.permitted).toBe(true);
    expect(moved.changing).toBe(true);
    expect(moved.preservedText).toEqual('Keep this draft');
    expect(moved.preservePostingStyle).toBe(true);
    expect(moved.rotateIdempotencyKey).toBe(true);
    expect(moved.nextIdempotencyKey).toEqual('key-next');
    expect(moved.canSend).toBe(false);
  });

  it('does not keep media uploaded for another identity', () => {
    const plan = resolveSenderIdentitySwitch({
      fromIdentityId: 'local:7',
      toIdentity: ready('local:42'),
      sessionIdentityId: 'local:42',
      draft: draft({
        media: [
          { id: 'previous', ownerIdentityId: 'local:7' },
          { id: 'unstamped' },
          { id: 'already-session', ownerIdentityId: 'local:42' },
        ],
      }),
      nextIdempotencyKey: 'key-next',
    });

    expect(plan.rejectedMediaIds).toEqual(['previous', 'unstamped']);
    expect(plan.keptMediaIds).toEqual(['already-session']);
    expect(plan.discardMedia).toBe(true);
  });

  it('does not reuse group viewer follows or affiliations for the next sender', () => {
    const plan = resolveSenderIdentitySwitch({
      fromIdentityId: 'local:7',
      toIdentity: ready('local:42'),
      sessionIdentityId: 'local:42',
      draft: draft({
        groupId: 'group-1',
        postingContext: {
          locks: { privacy: 'public' },
          viewerEvidence: {
            follows: ['old-follow-token'],
            affiliations: ['old-affiliation-token'],
          },
        },
      }),
      nextIdempotencyKey: 'key-next',
    });

    expect(plan.refreshGroupDiscovery).toBe(true);
    expect(plan.reuseViewerEvidence).toBe(false);
    expect(plan.reuseFollows).toBe(false);
    expect(plan.reuseAffiliations).toBe(false);
    expect(plan.discardViewerEvidence).toBe(true);
    expect(plan.nextViewerIdentityId).toEqual('local:42');
    expect(JSON.stringify(plan)).not.toContain('old-follow-token');
    expect(JSON.stringify(plan)).not.toContain('old-affiliation-token');
  });

  it('refuses an unregistered, unauthorized, or unsupported identity', () => {
    const base = {
      fromIdentityId: 'local:42',
      sessionIdentityId: 'local:42',
      draft: draft(),
      nextIdempotencyKey: 'key-next',
    };

    expect(resolveSenderIdentitySwitch({
      ...base,
      toIdentity: { id: 'local:99', registered: false, authorization: 'ready', kind: 'local', provider: 'fedibird' },
    })).toEqual(expect.objectContaining({ permitted: false, reason: 'unregistered' }));

    expect(resolveSenderIdentitySwitch({
      ...base,
      toIdentity: ready('local:42', { authorization: 'unavailable' }),
    })).toEqual(expect.objectContaining({ permitted: false, reason: 'unauthorized', canSend: false }));

    expect(resolveSenderIdentitySwitch({
      ...base,
      toIdentity: ready('bsky:1', { kind: 'bluesky', provider: 'bluesky' }),
    })).toEqual(expect.objectContaining({ permitted: false, reason: 'unsupported' }));

    expect(resolveSenderIdentitySwitch({
      ...base,
      toIdentity: ready('local:99'),
    })).toEqual(expect.objectContaining({ permitted: false, reason: 'not_enabled' }));
  });

  it('lets the sender and the destination override a posting style', () => {
    const plan = resolveSenderIdentitySwitch({
      fromIdentityId: 'local:42',
      toIdentity: ready('local:42', { authorization: 'unavailable', capabilities: { post: 'unavailable' } }),
      sessionIdentityId: 'local:42',
      draft: draft({
        userPostingContext: { privacy: 'private', authorization: 'ready' },
        manual: { privacy: 'direct', capabilities: { post: 'supported' } },
        postingContext: { locks: { privacy: 'public' } },
      }),
    });

    expect(plan.preservePostingStyle).toBe(true);
    expect(plan.style.order).toEqual(['identity', 'posting_context', 'user_posting_context', 'manual']);
    expect(plan.style.values.privacy).toEqual('public');
    expect(plan.style.values.authorization).toBeUndefined();
    expect(plan.style.values.capabilities).toBeUndefined();
    expect(plan.style.canPost).toBe(false);
    expect(plan.preservedText).toEqual('Keep this draft');
  });
});
