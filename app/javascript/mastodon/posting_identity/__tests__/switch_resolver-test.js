import { resolveSenderIdentitySwitch } from '../switch_resolver';

const capabilities = (post = 'supported', media = 'supported') => ({
  post,
  media,
  reply: 'supported',
  group: 'supported',
  schedule: 'supported',
});

const current = (overrides = {}) => ({
  identityId: 'local:123',
  status: 'ready',
  text: 'hello',
  postingStyle: { id: 'style-1' },
  postingContext: { key: 'group:9' },
  poll: { options: ['yes', 'no'] },
  mediaIds: ['media-1'],
  mediaUploading: false,
  replyTo: 'status-1',
  quoteFrom: 'status-2',
  editingStatusId: null,
  scheduledStatusId: null,
  groupDestination: true,
  viewerAccountId: '123',
  postingContextAccountId: '456',
  idempotencyKey: 'idem-old',
  authenticatedAccountId: '123',
  ...overrides,
});

const nextIdentity = (overrides = {}) => ({
  id: 'local:999',
  kind: 'local',
  authorization: 'ready',
  accountId: '999',
  capabilities: capabilities(),
  ...overrides,
});

describe('resolveSenderIdentitySwitch', () => {
  it('keeps text, style, poll, and posting context, and drops media owned by the previous sender', () => {
    const source = current();
    const decision = resolveSenderIdentitySwitch(source, nextIdentity(), { nextIdempotencyKey: 'idem-new' });

    expect(decision.permittedNow).toBe(false);
    expect(decision.blockers).toContain('not_enabled');
    expect(decision.canSend).toBe(false);
    expect(decision.effects.preserve.text).toBe('hello');
    expect(decision.effects.preserve.postingStyle).toBe(source.postingStyle);
    expect(decision.effects.preserve.postingContext).toBe(source.postingContext);
    expect(decision.effects.preserve.poll).toBe(source.poll);
    expect(decision.effects.postingContext.preserved).toBe(true);
    expect(decision.effects.media.ownedByIdentityId).toBe('local:123');
    expect(decision.effects.media.keepIds).toEqual([]);
    expect(decision.effects.media.discardIds).toEqual(['media-1']);
    expect(decision.effects.reply.mustRevalidate).toBe(true);
    expect(decision.effects.quote.mustRevalidate).toBe(true);
  });

  it('rotates the idempotency key when the sender would change', () => {
    const kept = resolveSenderIdentitySwitch(current(), nextIdentity({ id: 'local:123', accountId: '123' }), {
      nextIdempotencyKey: 'idem-unused',
    });
    const changed = resolveSenderIdentitySwitch(current(), nextIdentity(), { nextIdempotencyKey: 'idem-new' });
    const missing = resolveSenderIdentitySwitch(current(), nextIdentity(), { nextIdempotencyKey: 'idem-old' });

    expect(kept.changed).toBe(false);
    expect(kept.effects.idempotencyKeyRotated).toBe(false);
    expect(kept.effects.idempotencyKey).toBe('idem-old');
    expect(changed.effects.idempotencyKeyRotated).toBe(true);
    expect(changed.effects.idempotencyKey).toBe('idem-new');
    expect(changed.effects.idempotencyKey).not.toBe('idem-old');
    expect(missing.effects.idempotencyKey).toBeNull();
  });

  it('does not reuse group viewer evidence from the previous sender', () => {
    const decision = resolveSenderIdentitySwitch(current(), nextIdentity(), { nextIdempotencyKey: 'idem-new' });

    expect(decision.effects.group.refreshDiscovery).toBe(true);
    expect(decision.effects.group.previousViewerAccountId).toBe('123');
    expect(decision.effects.group.nextViewerAccountId).toBe('999');
    expect(decision.effects.group.reusePreviousViewerEvidence).toBe(false);
    expect(decision.effects.group.affiliations).toBeUndefined();
    expect(decision.effects.postingContext.viewerEvidenceStale).toBe(true);
    expect(JSON.stringify(decision.effects.group)).not.toContain('following');
  });

  it('refuses an unresolved, unauthorized, unsupported, or in-progress sender', () => {
    expect(resolveSenderIdentitySwitch(current(), null).blockers).toContain('unresolved');
    expect(resolveSenderIdentitySwitch(current(), null).canSend).toBe(false);
    expect(resolveSenderIdentitySwitch(current(), nextIdentity({ authorization: 'restricted' })).blockers).toContain('unauthorized');
    expect(resolveSenderIdentitySwitch(current(), nextIdentity({ capabilities: capabilities('unavailable') })).blockers).toContain('unsupported');
    expect(resolveSenderIdentitySwitch(current({ status: 'switching' }), nextIdentity({ id: 'local:123', accountId: '123' })).blockers).toContain('switching');
    expect(resolveSenderIdentitySwitch(current({ status: 'unresolved' }), nextIdentity({ id: 'local:123', accountId: '123' })).canSend).toBe(false);
    expect(resolveSenderIdentitySwitch(current({ mediaUploading: true }), nextIdentity({ id: 'local:123', accountId: '123' })).blockers).toContain('media_uploading');
    expect(resolveSenderIdentitySwitch(current({ mediaUploading: true }), nextIdentity({ id: 'local:123', accountId: '123' })).canSend).toBe(false);
  });

  it('does not enable a switch to another local or external identity in this phase', () => {
    const external = resolveSenderIdentitySwitch(current(), nextIdentity({
      id: 'bluesky:alice',
      kind: 'bluesky',
      accountId: 'alice',
    }));
    const delegated = resolveSenderIdentitySwitch(current(), nextIdentity({
      id: 'local:999',
      kind: 'local',
      authorization: 'ready',
      accountId: '999',
    }));

    expect(external.permittedNow).toBe(false);
    expect(delegated.permittedNow).toBe(false);
    expect(external.blockers).toContain('not_enabled');
    expect(delegated.effects.edit.transferable).toBe(false);
    expect(resolveSenderIdentitySwitch(current({ editingStatusId: 'status-9' }), nextIdentity()).blockers).toContain('edit_bound_to_sender');
    expect(resolveSenderIdentitySwitch(current({ scheduledStatusId: 'sched-1' }), nextIdentity()).blockers).toContain('schedule_bound_to_sender');
  });

  it('keeps the current sender able to post when nothing changes', () => {
    const decision = resolveSenderIdentitySwitch(current({
      mediaIds: [],
      replyTo: null,
      quoteFrom: null,
      groupDestination: false,
      postingContextAccountId: null,
    }), nextIdentity({ id: 'local:123', accountId: '123' }));

    expect(decision.changed).toBe(false);
    expect(decision.canSend).toBe(true);
    expect(decision.permittedNow).toBe(false);
    expect(decision.effects.media.keepIds).toEqual([]);
    expect(decision.effects.group.reusePreviousViewerEvidence).toBe(true);
    expect(decision.effects.group.refreshDiscovery).toBe(false);
  });
});
