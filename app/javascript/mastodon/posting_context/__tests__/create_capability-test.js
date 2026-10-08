import { Map as ImmutableMap, fromJS } from 'immutable';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

import { applyComposerPostingContext, createComposer, targetComposerAction } from '../../actions/composer';
import { POSTING_CONTEXT_CACHE_TTL } from '../../actions/posting_contexts';
import composer from '../../reducers/composer';
import composers from '../../reducers/composers';
import { groupPostingContext } from '../fixtures/group_context_fixture';
import { mitraGroupPostingContext } from '../fixtures/mitra_group_context_fixture';
import { buildHashtagTimelinePostingContext } from '../hashtag';
import { createCapabilityNotice, selectComposerEffectiveCreateCapability } from '../create_capability';

const NOW = 1_700_000_000_000;

const permissionEvidence = (status, viaRelationship = null) => ({
  status,
  source: 'fep-5219',
  viaRelationship,
  authority: 'protocol',
});

const viewerEvidence = (create, view = null) => ({
  affiliations: {
    source: 'fep-5219-affiliations',
    snapshotStatus: 'fresh',
    fetchedAt: '2026-10-07T01:23:45Z',
    relationships: [],
  },
  permissions: {
    create,
    ...(view ? { view } : {}),
  },
});

const discoveryRecord = ({
  status = 'resolved',
  adapter = null,
  authority = null,
  viewerEvidence: evidence = null,
  receivedAt = NOW,
  refreshing = false,
  refreshError = null,
  reason = null,
} = {}) => fromJS({
  status,
  context: null,
  discovery: {
    mechanism: adapter ? 'test' : null,
    adapter,
    authority,
  },
  reason,
  error: null,
  viewerEvidence: evidence,
  receivedAt,
  refreshing,
  refreshError,
});

const withPrivacy = (composerState, privacy) => composer(composerState, {
  type: 'COMPOSE_VISIBILITY_CHANGE',
  value: privacy,
});

const primaryState = ({
  postingContext,
  accountId,
  privacy = 'public',
  relationship,
  discovery,
  discoveryAccountId,
} = {}) => {
  let composerState = composer(undefined, applyComposerPostingContext('primary', postingContext, accountId));

  if (privacy) {
    composerState = withPrivacy(composerState, privacy);
  }

  const relationships = relationship ? ImmutableMap({
    [relationship.id]: ImmutableMap(relationship),
  }) : ImmutableMap();
  const cacheId = discoveryAccountId || accountId;
  const postingContexts = discovery && cacheId ? ImmutableMap({
    [String(cacheId)]: discovery,
  }) : ImmutableMap();

  return ImmutableMap({
    compose: composerState,
    relationships,
    posting_contexts: postingContexts,
  });
};

const localDiscovery = (evidence = null, extras = {}) => discoveryRecord({
  adapter: 'fedibird_group',
  authority: 'server',
  viewerEvidence: evidence,
  ...extras,
});

const mitraDiscovery = (evidence = null, extras = {}) => discoveryRecord({
  adapter: 'mitra_group',
  authority: 'compatibility',
  viewerEvidence: evidence,
  ...extras,
});

const capabilityFor = (state, composerId = 'primary', now = NOW) => (
  selectComposerEffectiveCreateCapability(state, composerId, now)
);

describe('selectComposerEffectiveCreateCapability', () => {
  it('lets a local group attempt when evidence is absent and compliance is valid', () => {
    const capability = capabilityFor(primaryState({
      postingContext: groupPostingContext,
      accountId: '123',
      relationship: { id: '123', following: true, requested: false },
      discovery: localDiscovery(null),
    }));

    expect(capability.permission).toEqual({
      status: 'not_applicable',
      source: null,
      viaRelationship: null,
      confirmed: false,
      freshness: 'not_applicable',
    });
    expect(capability.delivery).toEqual({
      status: 'supported',
      authority: 'server',
      adapter: 'fedibird_group',
    });
    expect(capability.compliance.valid).toBe(true);
    expect(capability.canAttempt).toBe(true);
    expect(capability.reason).toBeNull();
    expect(createCapabilityNotice(capability)).toBeNull();
  });

  it('does not turn stored protocol evidence into local create permission', () => {
    const capability = capabilityFor(primaryState({
      postingContext: groupPostingContext,
      accountId: '123',
      relationship: { id: '123', following: true, requested: false },
      discovery: localDiscovery(viewerEvidence(permissionEvidence('allowed', 'admin'))),
    }));

    expect(capability.permission.status).toBe('not_applicable');
    expect(capability.permission.confirmed).toBe(false);
    expect(capability.delivery.authority).toBe('server');
    expect(capability.canAttempt).toBe(true);
    expect(createCapabilityNotice(capability)).toBeNull();
  });

  it('blocks a local group when the follow requirement is not satisfied', () => {
    const capability = capabilityFor(primaryState({
      postingContext: groupPostingContext,
      accountId: '123',
      relationship: { id: '123', following: false, requested: false },
      discovery: localDiscovery(null),
    }));

    expect(capability.compliance.valid).toBe(false);
    expect(capability.compliance.followingAccounts[0].status).toBe('not_following');
    expect(capability.canAttempt).toBe(false);
    expect(capability.reason).toBe('compliance');
    expect(capability.permission.status).toBe('not_applicable');
  });

  it('attempts a Mitra post when create is allowed and compliance is valid', () => {
    const capability = capabilityFor(primaryState({
      postingContext: mitraGroupPostingContext,
      accountId: '456',
      discovery: mitraDiscovery(viewerEvidence(permissionEvidence('allowed', 'trusted-poster'))),
    }));

    expect(capability.permission).toMatchObject({
      status: 'allowed',
      source: 'fep-5219',
      viaRelationship: 'trusted-poster',
      confirmed: true,
    });
    expect(capability.delivery).toEqual({
      status: 'supported',
      authority: 'compatibility',
      adapter: 'mitra_group',
    });
    expect(capability.compliance.valid).toBe(true);
    expect(capability.canAttempt).toBe(true);
    expect(capability.reason).toBeNull();
    expect(createCapabilityNotice(capability)).toBe('allowed_compatibility');
  });

  it('still attempts a Mitra post when create is unknown and compliance is valid', () => {
    const capability = capabilityFor(primaryState({
      postingContext: mitraGroupPostingContext,
      accountId: '456',
      discovery: mitraDiscovery(viewerEvidence(permissionEvidence('unknown'))),
    }));

    expect(capability.permission.status).toBe('unknown');
    expect(capability.permission.confirmed).toBe(false);
    expect(capability.delivery.authority).toBe('compatibility');
    expect(capability.compliance.valid).toBe(true);
    expect(capability.canAttempt).toBe(true);
    expect(createCapabilityNotice(capability)).toBe('unknown_compatibility');
  });

  it('blocks a Mitra post with unknown create permission when visibility is invalid', () => {
    const capability = capabilityFor(primaryState({
      postingContext: mitraGroupPostingContext,
      accountId: '456',
      privacy: 'private',
      discovery: mitraDiscovery(viewerEvidence(permissionEvidence('unknown'))),
    }));

    expect(capability.permission.status).toBe('unknown');
    expect(capability.compliance.valid).toBe(false);
    expect(capability.canAttempt).toBe(false);
    expect(capability.reason).toBe('compliance');
    expect(createCapabilityNotice(capability)).toBe('unknown_compatibility');
  });

  it('keeps allowed evidence for an unsupported group and still refuses the group path', () => {
    const capability = capabilityFor(primaryState({
      postingContext: mitraGroupPostingContext,
      accountId: '456',
      discovery: discoveryRecord({
        status: 'unsupported',
        reason: 'no_supported_adapter',
        viewerEvidence: viewerEvidence(permissionEvidence('allowed', 'trusted-poster')),
      }),
    }));

    expect(capability.permission.status).toBe('allowed');
    expect(capability.permission.confirmed).toBe(true);
    expect(capability.delivery.status).toBe('unsupported');
    expect(capability.canAttempt).toBe(false);
    expect(capability.reason).toBe('delivery_unsupported');
    expect(createCapabilityNotice(capability)).toBe('allowed_unsupported');
  });

  it('refuses an unsupported group when create is unknown', () => {
    const capability = capabilityFor(primaryState({
      postingContext: null,
      accountId: '456',
      discovery: discoveryRecord({
        status: 'unsupported',
        reason: 'no_supported_adapter',
        viewerEvidence: viewerEvidence(permissionEvidence('unknown')),
      }),
    }));

    expect(capability.permission.status).toBe('unknown');
    expect(capability.canAttempt).toBe(false);
    expect(capability.reason).toBe('delivery_unsupported');
    expect(createCapabilityNotice(capability)).toBe('unsupported');
  });

  it('does not let view allowed change an unknown create decision', () => {
    const capability = capabilityFor(primaryState({
      postingContext: mitraGroupPostingContext,
      accountId: '456',
      discovery: mitraDiscovery(viewerEvidence(
        permissionEvidence('unknown'),
        permissionEvidence('allowed', 'member'),
      )),
    }));

    expect(capability.permission.status).toBe('unknown');
    expect(capability.permission.viaRelationship).toBeNull();
    expect(capability.canAttempt).toBe(true);
    expect(createCapabilityNotice(capability)).toBe('unknown_compatibility');
  });

  it('treats canCreate none as positive create evidence', () => {
    const capability = capabilityFor(primaryState({
      postingContext: mitraGroupPostingContext,
      accountId: '456',
      discovery: mitraDiscovery(viewerEvidence(permissionEvidence('allowed', 'none'))),
    }));

    expect(capability.permission).toMatchObject({
      status: 'allowed',
      viaRelationship: 'none',
      confirmed: true,
    });
    expect(capability.delivery.authority).toBe('compatibility');
    expect(capability.canAttempt).toBe(true);
    expect(createCapabilityNotice(capability)).toBe('allowed_compatibility');
  });

  it('refuses a send when the composer target does not match the resolved context', () => {
    const state = primaryState({
      postingContext: groupPostingContext,
      accountId: '123',
      relationship: { id: '123', following: true, requested: false },
      discovery: mitraDiscovery(viewerEvidence(permissionEvidence('unknown'))),
      discoveryAccountId: '999',
    }).setIn(['compose', 'posting_context_account_id'], '999');
    const capability = capabilityFor(state);

    expect(state.getIn(['compose', 'context', 'resolvedAccountId'])).toBe('123');
    expect(state.getIn(['posting_contexts', '123'])).toBeUndefined();
    expect(capability.permission.status).toBe('unknown');
    expect(capability.permission.viaRelationship).toBeNull();
    expect(capability.canAttempt).toBe(false);
    expect(capability.reason).toBe('target_mismatch');
  });

  it('does not read an account id out of the context key or the audience id', () => {
    const state = primaryState({
      postingContext: {
        ...mitraGroupPostingContext,
        key: 'protocol:fep-1b12-group:456',
      },
      accountId: '789',
      discovery: discoveryRecord({
        status: 'unsupported',
        reason: 'no_supported_adapter',
        viewerEvidence: viewerEvidence(permissionEvidence('unknown')),
      }),
      discoveryAccountId: '789',
    });
    const otherAllowed = state.setIn(['posting_contexts', '456'], mitraDiscovery(
      viewerEvidence(permissionEvidence('allowed', 'trusted-poster')),
    ));
    const capability = capabilityFor(otherAllowed);

    expect(otherAllowed.getIn(['compose', 'context', 'resolvedAccountId'])).toBe('789');
    expect(otherAllowed.getIn(['compose', 'context', 'protocol', 'activityPub', 'audience', 'accountId'])).toBe('456');
    expect(capability.permission.status).toBe('unknown');
    expect(capability.delivery.status).toBe('unsupported');
    expect(capability.canAttempt).toBe(false);
  });

  it('leaves a composer without a group target on the existing compliance path', () => {
    const capability = capabilityFor(primaryState({
      postingContext: buildHashtagTimelinePostingContext('foo'),
      privacy: null,
    }));

    expect(capability.permission.status).toBe('not_applicable');
    expect(capability.delivery.status).toBe('not_applicable');
    expect(capability.compliance.valid).toBe(true);
    expect(capability.canAttempt).toBe(true);
    expect(capability.reason).toBeNull();
    expect(createCapabilityNotice(capability)).toBeNull();
  });

  it('does not apply group create permission rules to existing or scheduled edits', () => {
    const blockedGroup = primaryState({
      postingContext: groupPostingContext,
      accountId: '123',
      privacy: 'private',
      relationship: { id: '123', following: false, requested: false },
      discovery: discoveryRecord({
        status: 'unsupported',
        reason: 'no_supported_adapter',
        viewerEvidence: viewerEvidence(permissionEvidence('unknown')),
      }),
    });
    const existing = blockedGroup.setIn(['compose', 'id'], 'status-9');
    const scheduled = blockedGroup.setIn(['compose', 'scheduled_status_id'], 'sched-1');
    const scheduledAudience = scheduled
      .setIn(['compose', 'draft_audience_account_id'], '456')
      .setIn(['compose', 'privacy'], 'private');
    const existingCapability = capabilityFor(existing);
    const scheduledCapability = capabilityFor(scheduled);
    const audienceCapability = capabilityFor(scheduledAudience);

    expect(existingCapability.canAttempt).toBe(true);
    expect(existingCapability.reason).toBeNull();
    expect(existingCapability.delivery.status).toBe('not_applicable');
    expect(scheduledCapability.canAttempt).toBe(true);
    expect(scheduledCapability.delivery.status).toBe('not_applicable');
    expect(audienceCapability.canAttempt).toBe(false);
    expect(audienceCapability.reason).toBe('compliance');
    expect(audienceCapability.delivery.status).toBe('not_applicable');
  });

  it('keeps the timeline target after the ordinary submit reset', () => {
    const state = primaryState({
      postingContext: groupPostingContext,
      accountId: '123',
      relationship: { id: '123', following: true, requested: false },
      discovery: localDiscovery(null),
    });
    const reset = state.set('compose', composer(state.get('compose'), {
      type: 'COMPOSE_SUBMIT_SUCCESS',
    }));

    expect(reset.getIn(['compose', 'text'])).toBe('');
    expect(reset.getIn(['compose', 'context', 'key'])).toBe('builtin:fedibird-group:123');
    expect(reset.getIn(['compose', 'posting_context_account_id'])).toBe('123');
    expect(capabilityFor(reset).canAttempt).toBe(true);
  });

  it('does not present refreshing, failed, or expired evidence as confirmed', () => {
    const base = {
      postingContext: mitraGroupPostingContext,
      accountId: '456',
    };
    const allowed = viewerEvidence(permissionEvidence('allowed', 'trusted-poster'));
    const refreshing = capabilityFor(primaryState({
      ...base,
      discovery: mitraDiscovery(allowed, { refreshing: true }),
    }));
    const failed = capabilityFor(primaryState({
      ...base,
      discovery: mitraDiscovery(allowed, { refreshError: true }),
    }));
    const stale = capabilityFor(primaryState({
      ...base,
      discovery: mitraDiscovery(allowed, { receivedAt: NOW - POSTING_CONTEXT_CACHE_TTL }),
    }), 'primary', NOW);

    [refreshing, failed, stale].forEach(capability => {
      expect(capability.permission.status).toBe('allowed');
      expect(capability.permission.confirmed).toBe(false);
      expect(capability.delivery.status).toBe('supported');
      expect(capability.delivery.authority).toBe('compatibility');
      expect(capability.canAttempt).toBe(true);
      expect(createCapabilityNotice(capability)).not.toBe('allowed_compatibility');
    });
    expect(createCapabilityNotice(refreshing)).toBe('refreshing');
    expect(createCapabilityNotice(failed)).toBe('refresh_failed');
    expect(createCapabilityNotice(stale)).toBe('unknown_compatibility');
  });

  it('refuses a group target that has no resolved context', () => {
    const capability = capabilityFor(primaryState({
      postingContext: null,
      accountId: '456',
      discovery: discoveryRecord({ status: 'loading' }),
    }));

    expect(capability.delivery.status).toBe('unresolved');
    expect(capability.permission.status).toBe('unknown');
    expect(capability.canAttempt).toBe(false);
    expect(capability.reason).toBe('delivery_unresolved');
    expect(createCapabilityNotice(capability)).toBe('unresolved');
  });

  it('defers not_applicable discovery to the normal posting path', () => {
    const capability = capabilityFor(primaryState({
      postingContext: buildHashtagTimelinePostingContext('foo'),
      accountId: '456',
      privacy: null,
      discovery: discoveryRecord({ status: 'not_applicable', reason: 'not_group' }),
    }));

    expect(capability.delivery.status).toBe('not_applicable');
    expect(capability.permission.status).toBe('not_applicable');
    expect(capability.canAttempt).toBe(true);
    expect(createCapabilityNotice(capability)).toBeNull();
  });

  it('keeps permission evidence separate across two composers', () => {
    let registry = composers(undefined, { type: '@@INIT' });

    registry = composers(registry, createComposer('composer-a'));
    registry = composers(registry, createComposer('composer-b'));
    registry = composers(registry, applyComposerPostingContext('composer-a', groupPostingContext, '123'));
    registry = composers(registry, applyComposerPostingContext('composer-b', mitraGroupPostingContext, '456'));
    registry = composers(registry, targetComposerAction({ type: 'COMPOSE_VISIBILITY_CHANGE', value: 'public' }, 'composer-a'));
    registry = composers(registry, targetComposerAction({ type: 'COMPOSE_VISIBILITY_CHANGE', value: 'public' }, 'composer-b'));

    const state = ImmutableMap({
      composers: registry,
      relationships: ImmutableMap({
        '123': ImmutableMap({ following: false, requested: false }),
      }),
      posting_contexts: ImmutableMap({
        '123': localDiscovery(viewerEvidence(permissionEvidence('allowed', 'admin'))),
        '456': mitraDiscovery(viewerEvidence(permissionEvidence('unknown'))),
      }),
    });
    const local = capabilityFor(state, 'composer-a');
    const remote = capabilityFor(state, 'composer-b');

    expect(local.permission.status).toBe('not_applicable');
    expect(local.canAttempt).toBe(false);
    expect(local.reason).toBe('compliance');
    expect(remote.permission.status).toBe('unknown');
    expect(remote.permission.viaRelationship).toBeNull();
    expect(remote.delivery.authority).toBe('compatibility');
    expect(remote.canAttempt).toBe(true);
  });

  it('drops the previous group evidence when the target account changes', () => {
    let composerState = composer(undefined, applyComposerPostingContext('primary', groupPostingContext, '123'));

    composerState = withPrivacy(composerState, 'public');
    composerState = composer(composerState, applyComposerPostingContext('primary', mitraGroupPostingContext, '456'));

    const state = ImmutableMap({
      compose: composerState,
      relationships: ImmutableMap(),
      posting_contexts: ImmutableMap({
        '123': mitraDiscovery(viewerEvidence(permissionEvidence('allowed', 'trusted-poster'))),
        '456': mitraDiscovery(viewerEvidence(permissionEvidence('unknown'))),
      }),
    });
    const capability = capabilityFor(state);

    expect(composerState.get('posting_context_account_id')).toBe('456');
    expect(composerState.getIn(['context', 'resolvedAccountId'])).toBe('456');
    expect(capability.permission.status).toBe('unknown');
    expect(capability.permission.viaRelationship).toBeNull();
    expect(capability.canAttempt).toBe(true);
    expect(createCapabilityNotice(capability)).toBe('unknown_compatibility');
  });
});
