import { Map as ImmutableMap, fromJS } from 'immutable';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

import { applyComposerPostingContext, createComposer, targetComposerAction, toggleComposerManagedHashtag } from '../../actions/composer';
import { POSTING_CONTEXT_CACHE_TTL } from '../../actions/posting_contexts';
import composer from '../../reducers/composer';
import composers from '../../reducers/composers';
import { groupPostingContext } from '../fixtures/group_context_fixture';
import { mitraGroupPostingContext } from '../fixtures/mitra_group_context_fixture';
import { nodebbGroupPostingContext, nodebbGroupPostingContextFor } from '../fixtures/nodebb_group_context_fixture';
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
  context = null,
  adapter = null,
  authority = null,
  viewerEvidence: evidence = null,
  receivedAt = NOW,
  refreshing = false,
  refreshError = null,
  reason = null,
} = {}) => fromJS({
  status,
  context,
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
  const storedDiscovery = discovery && discovery.get && discovery.get('status') === 'resolved' && !discovery.get('context') && postingContext
    ? discovery.set('context', fromJS(postingContext))
    : discovery;
  const postingContexts = storedDiscovery && cacheId ? ImmutableMap({
    [String(cacheId)]: storedDiscovery,
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

const nodebbDiscovery = (evidence = null, extras = {}) => discoveryRecord({
  adapter: 'nodebb_group',
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

  it('does not delegate an explicit group target when discovery is not applicable', () => {
    const capability = capabilityFor(primaryState({
      postingContext: groupPostingContext,
      accountId: '123',
      relationship: { id: '123', following: true, requested: false },
      discovery: discoveryRecord({ status: 'not_applicable', reason: 'not_group' }),
    }));

    expect(capability.delivery.status).toBe('not_applicable');
    expect(capability.permission.status).toBe('not_applicable');
    expect(capability.canAttempt).toBe(false);
    expect(capability.reason).toBe('target_mismatch');
    expect(createCapabilityNotice(capability)).toBe('mismatch');
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
        '123': localDiscovery(viewerEvidence(permissionEvidence('allowed', 'admin')), {
          context: groupPostingContext,
        }),
        '456': mitraDiscovery(viewerEvidence(permissionEvidence('unknown')), {
          context: mitraGroupPostingContext,
        }),
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
        '123': mitraDiscovery(viewerEvidence(permissionEvidence('allowed', 'trusted-poster')), {
          context: groupPostingContext,
        }),
        '456': mitraDiscovery(viewerEvidence(permissionEvidence('unknown')), {
          context: mitraGroupPostingContext,
        }),
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

  it('refuses a resolved group target when no composer context is applied', () => {
    const capability = capabilityFor(primaryState({
      postingContext: null,
      accountId: '456',
      discovery: mitraDiscovery(viewerEvidence(permissionEvidence('allowed', 'trusted-poster')), {
        context: mitraGroupPostingContext,
      }),
    }));

    expect(capability.delivery.status).toBe('supported');
    expect(capability.permission.confirmed).toBe(true);
    expect(capability.canAttempt).toBe(false);
    expect(capability.reason).toBe('target_mismatch');
    expect(createCapabilityNotice(capability)).toBe('mismatch');
  });

  it('refuses a group target whose composer context key and resolved account are empty', () => {
    const capability = capabilityFor(primaryState({
      postingContext: null,
      accountId: '456',
      discovery: mitraDiscovery(viewerEvidence(permissionEvidence('unknown')), {
        context: mitraGroupPostingContext,
      }),
    }));

    expect(capability.canAttempt).toBe(false);
    expect(capability.reason).toBe('target_mismatch');
  });

  it('refuses a group target that still has another target context applied', () => {
    const state = primaryState({
      postingContext: groupPostingContext,
      accountId: '123',
      relationship: { id: '123', following: true, requested: false },
      discovery: mitraDiscovery(viewerEvidence(permissionEvidence('allowed', 'trusted-poster')), {
        context: mitraGroupPostingContext,
      }),
      discoveryAccountId: '456',
    }).setIn(['compose', 'posting_context_account_id'], '456');
    const capability = capabilityFor(state);

    expect(state.getIn(['compose', 'context', 'key'])).toBe('builtin:fedibird-group:123');
    expect(state.getIn(['compose', 'context', 'resolvedAccountId'])).toBe('123');
    expect(capability.permission.confirmed).toBe(true);
    expect(capability.canAttempt).toBe(false);
    expect(capability.reason).toBe('target_mismatch');
    expect(createCapabilityNotice(capability)).toBe('mismatch');
  });

  it('keeps an ordinary composer on compliance when it has no group target', () => {
    const capability = capabilityFor(primaryState({
      privacy: 'private',
    }));

    expect(capability.permission.status).toBe('not_applicable');
    expect(capability.delivery.status).toBe('not_applicable');
    expect(capability.compliance.valid).toBe(true);
    expect(capability.canAttempt).toBe(true);
    expect(capability.reason).toBeNull();
  });

  it('does not send with a stale context after constraints change under the same key', () => {
    const updated = {
      ...mitraGroupPostingContext,
      constraints: {
        allowedVisibilities: ['public'],
      },
      protocol: {
        activityPub: {
          audience: {
            accountId: '456',
            acct: 'renamed@mitra.example',
            enforcement: 'required',
            ruleId: 'fep-1b12-group-audience',
          },
        },
      },
    };
    const capability = capabilityFor(primaryState({
      postingContext: mitraGroupPostingContext,
      accountId: '456',
      discovery: mitraDiscovery(viewerEvidence(permissionEvidence('unknown')), {
        context: updated,
      }),
    }));

    expect(capability.delivery.status).toBe('supported');
    expect(capability.compliance.valid).toBe(true);
    expect(capability.canAttempt).toBe(false);
    expect(capability.reason).toBe('target_mismatch');
    expect(createCapabilityNotice(capability)).toBe('mismatch');
  });

  it('allows the attempt once the updated context is applied', () => {
    const updated = {
      ...groupPostingContext,
      source: {
        id: groupPostingContext.source.id,
        revision: 2,
      },
      constraints: {
        allowedVisibilities: ['public', 'unlisted'],
      },
    };
    const stale = primaryState({
      postingContext: groupPostingContext,
      accountId: '123',
      relationship: { id: '123', following: true, requested: false },
      discovery: localDiscovery(null, { context: updated }),
    });
    const applied = stale.set('compose', composer(stale.get('compose'), applyComposerPostingContext('primary', updated, '123')));
    const before = capabilityFor(stale);
    const after = capabilityFor(applied);

    expect(before.canAttempt).toBe(false);
    expect(before.reason).toBe('target_mismatch');
    expect(after.compliance.valid).toBe(true);
    expect(after.canAttempt).toBe(true);
    expect(after.reason).toBeNull();
    expect(after.delivery.authority).toBe('server');
    expect(createCapabilityNotice(after)).toBeNull();
  });

  it('reports mismatch ahead of a refreshing permission', () => {
    const capability = capabilityFor(primaryState({
      postingContext: null,
      accountId: '456',
      discovery: mitraDiscovery(viewerEvidence(permissionEvidence('allowed', 'trusted-poster')), {
        context: mitraGroupPostingContext,
        refreshing: true,
      }),
    }));

    expect(capability.permission.status).toBe('allowed');
    expect(capability.permission.freshness).toBe('refreshing');
    expect(capability.permission.confirmed).toBe(false);
    expect(capability.canAttempt).toBe(false);
    expect(capability.reason).toBe('target_mismatch');
    expect(createCapabilityNotice(capability)).toBe('mismatch');
  });

  it('ignores composer hashtag suppressions when the discovery context matches', () => {
    const postingContext = {
      ...groupPostingContext,
      managed: {
        ...groupPostingContext.managed,
        hashtags: [
          {
            name: 'News',
            normalizedName: 'news',
            enforcement: 'advisory',
            ruleId: 'hashtag-news',
          },
        ],
      },
    };
    const state = primaryState({
      postingContext,
      accountId: '123',
      relationship: { id: '123', following: true, requested: false },
      discovery: localDiscovery(null),
    });
    const suppressed = state.set('compose', composer(
      state.get('compose'),
      toggleComposerManagedHashtag('primary', 'news'),
    ));
    const capability = capabilityFor(suppressed);

    expect(suppressed.getIn(['compose', 'context', 'suppressions', 'hashtags']).includes('news')).toBe(true);
    expect(capability.canAttempt).toBe(true);
    expect(capability.reason).toBeNull();
  });

  it('does not treat a failed revalidation as a fresh confirmation and still allows a compatibility attempt', () => {
    const allowed = capabilityFor(primaryState({
      postingContext: mitraGroupPostingContext,
      accountId: '456',
      discovery: mitraDiscovery(viewerEvidence(permissionEvidence('allowed', 'none'))),
    }).set('posting_context_revalidations', fromJS({
      '456': { state: 'failed', explicit: true, actor: 'failed', affiliations: 'failed' },
    })));
    const unknown = capabilityFor(primaryState({
      postingContext: mitraGroupPostingContext,
      accountId: '456',
      discovery: mitraDiscovery(viewerEvidence(permissionEvidence('unknown'))),
    }).set('posting_context_revalidations', fromJS({
      '456': { state: 'running', explicit: true },
    })));

    expect(allowed.permission.status).toBe('allowed');
    expect(allowed.permission.viaRelationship).toBe('none');
    expect(allowed.permission.confirmed).toBe(false);
    expect(allowed.canAttempt).toBe(true);
    expect(createCapabilityNotice(allowed)).not.toBe('allowed_compatibility');
    expect(unknown.permission.status).toBe('unknown');
    expect(unknown.canAttempt).toBe(true);
    expect(unknown.delivery.authority).toBe('compatibility');
  });

  it('does not apply another group revalidation result to the current target', () => {
    const capability = capabilityFor(primaryState({
      postingContext: mitraGroupPostingContext,
      accountId: '456',
      discovery: mitraDiscovery(viewerEvidence(permissionEvidence('allowed', 'trusted-poster'))),
    }).set('posting_context_revalidations', fromJS({
      '123': { state: 'failed', explicit: true, actor: 'failed', affiliations: 'failed' },
    })));

    expect(capability.permission.confirmed).toBe(true);
    expect(capability.canAttempt).toBe(true);
    expect(createCapabilityNotice(capability)).toBe('allowed_compatibility');
  });

  it('attempts a public NodeBB post when create is unknown and the context matches', () => {
    const state = primaryState({
      postingContext: nodebbGroupPostingContext,
      accountId: '456',
      discovery: nodebbDiscovery(viewerEvidence(permissionEvidence('unknown'))),
    });
    const capability = capabilityFor(state);

    expect(state.getIn(['compose', 'privacy'])).toBe('public');
    expect(capability.permission.status).toBe('unknown');
    expect(capability.permission.confirmed).toBe(false);
    expect(capability.delivery).toEqual({
      status: 'supported',
      authority: 'compatibility',
      adapter: 'nodebb_group',
    });
    expect(capability.compliance.valid).toBe(true);
    expect(capability.compliance.visibility.allowed).toEqual(['public']);
    expect(capability.canAttempt).toBe(true);
    expect(createCapabilityNotice(capability)).toBe('unknown_compatibility');
  });

  it('blocks an unlisted NodeBB post without changing the selected visibility', () => {
    const state = primaryState({
      postingContext: nodebbGroupPostingContext,
      accountId: '456',
      privacy: 'unlisted',
      discovery: nodebbDiscovery(viewerEvidence(permissionEvidence('unknown'))),
    });
    const blocked = capabilityFor(state);
    const published = state.set('compose', withPrivacy(state.get('compose'), 'public'));
    const allowed = capabilityFor(published);

    expect(state.getIn(['compose', 'privacy'])).toBe('unlisted');
    expect(blocked.compliance.valid).toBe(false);
    expect(blocked.canAttempt).toBe(false);
    expect(blocked.reason).toBe('compliance');
    expect(blocked.delivery.authority).toBe('compatibility');
    expect(published.getIn(['compose', 'privacy'])).toBe('public');
    expect(allowed.canAttempt).toBe(true);
    expect(allowed.reason).toBeNull();
  });

  it('does not describe an allowed NodeBB permission as guaranteed acceptance', () => {
    const capability = capabilityFor(primaryState({
      postingContext: nodebbGroupPostingContext,
      accountId: '456',
      discovery: nodebbDiscovery(viewerEvidence(permissionEvidence('allowed', 'none'))),
    }));

    expect(capability.permission.confirmed).toBe(true);
    expect(capability.canAttempt).toBe(true);
    expect(createCapabilityNotice(capability)).toBe('allowed_compatibility');
  });

  it('refuses a NodeBB target when the composer still has another group context', () => {
    const state = primaryState({
      postingContext: nodebbGroupPostingContext,
      accountId: '456',
      discovery: nodebbDiscovery(viewerEvidence(permissionEvidence('unknown')), {
        context: nodebbGroupPostingContextFor('789', 'other@nodebb.example'),
      }),
      discoveryAccountId: '789',
    }).setIn(['compose', 'posting_context_account_id'], '789');
    const capability = capabilityFor(state);

    expect(state.getIn(['compose', 'context', 'key'])).toBe('protocol:fep-1b12-nodebb:456');
    expect(capability.canAttempt).toBe(false);
    expect(capability.reason).toBe('target_mismatch');
    expect(createCapabilityNotice(capability)).toBe('mismatch');
  });

  it('does not turn a completed NodeBB revalidation into create permission', () => {
    const completed = capabilityFor(primaryState({
      postingContext: nodebbGroupPostingContext,
      accountId: '456',
      discovery: nodebbDiscovery(viewerEvidence(permissionEvidence('unknown'))),
    }).set('posting_context_revalidations', fromJS({
      '456': { state: 'completed', explicit: true, actor: 'refreshed', affiliations: 'refreshed' },
    })));
    const failed = capabilityFor(primaryState({
      postingContext: nodebbGroupPostingContext,
      accountId: '456',
      discovery: nodebbDiscovery(viewerEvidence(permissionEvidence('allowed', 'none'))),
    }).set('posting_context_revalidations', fromJS({
      '456': { state: 'failed', explicit: true, actor: 'failed', affiliations: 'failed' },
    })));

    expect(completed.permission.status).toBe('unknown');
    expect(completed.permission.confirmed).toBe(false);
    expect(completed.canAttempt).toBe(true);
    expect(completed.delivery).toEqual({
      status: 'supported',
      authority: 'compatibility',
      adapter: 'nodebb_group',
    });
    expect(createCapabilityNotice(completed)).toBe('unknown_compatibility');
    expect(failed.permission.status).toBe('allowed');
    expect(failed.permission.confirmed).toBe(false);
    expect(failed.canAttempt).toBe(true);
    expect(createCapabilityNotice(failed)).not.toBe('allowed_compatibility');
  });
});
