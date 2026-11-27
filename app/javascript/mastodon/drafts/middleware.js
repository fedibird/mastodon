import { Map as ImmutableMap } from 'immutable';
import { me } from '../initial_state';
import { selectComposer } from '../selectors/composer';
import { PRIMARY_COMPOSER_ID } from '../utils/composer';
import { COMPOSER_DRAFT_STATUS } from '../actions/composer';
import { createComposerDraftSession } from './session';
import { browserPostDraftRequest } from './sync_client';
import { createPostDraftSync } from './sync';
import { createIndexedDbDraftBackend, createIndexedDbSyncLedger } from './storage';

let sharedSession = null;

export function getComposerDraftSession () {
  return sharedSession;
}

function collectComposers (state) {
  if (!state || typeof state.get !== 'function') {
    return [];
  }

  const composers = [];
  const primary = selectComposer(state, PRIMARY_COMPOSER_ID);

  if (primary) {
    composers.push({ composerId: PRIMARY_COMPOSER_ID, state: primary });
  }

  const byId = state.getIn(['composers', 'byId'], ImmutableMap());

  if (byId && typeof byId.forEach === 'function') {
    byId.forEach((composerState, composerId) => {
      composers.push({ composerId, state: composerState });
    });
  }

  return composers;
}

export function composerDraftMiddleware (options = {}) {
  let storeRef = null;
  let session = options.session || null;
  const backend = options.backend || (session ? null : createIndexedDbDraftBackend());
  const serverSync = options.serverSync || (options.enableServerSync ? createPostDraftSync({
    ledger: options.ledger || createIndexedDbSyncLedger(),
    request: (spec) => browserPostDraftRequest(() => storeRef && storeRef.getState(), spec),
    schedule: options.serverSchedule,
    cancel: options.serverCancel,
    online: options.online,
    subscribeOnline: options.subscribeOnline,
    serverDebounceMs: options.serverDebounceMs,
    onAcknowledged: (detail) => (session && typeof session.noteAcknowledged === 'function' ? session.noteAcknowledged(detail) : undefined),
  }) : null);

  if (!session) {
    session = createComposerDraftSession({
      backend,
      debounceMs: options.debounceMs,
      schedule: options.schedule,
      cancel: options.cancel,
      now: options.now,
      createId: options.createId,
      serverSync,
    });
  }

  sharedSession = session;
  let lastPublished = '';
  let primed = false;

  const accountIdFor = () => (options.accountId === undefined ? me : options.accountId);

  return store => {
    storeRef = store;
    const target = options.target === undefined && typeof window !== 'undefined' ? window : options.target;

    session.bindLifecycle(target);
    session.subscribe(() => {
      const view = session.snapshot();
      const encoded = JSON.stringify(view);

      if (encoded === lastPublished) {
        return;
      }

      lastPublished = encoded;
      store.dispatch({
        type: COMPOSER_DRAFT_STATUS,
        view,
        meta: { composerDraftInternal: true },
      });
    });

    return next => (action) => {
      if (action && action.meta && action.meta.composerDraftInternal) {
        return next(action);
      }

      const result = next(action);
      const accountId = accountIdFor();

      if (!accountId) {
        if (session.releaseServerSync) {
          session.releaseServerSync();
        }

        return result;
      }

      session.sync({
        accountId,
        action,
        composers: collectComposers(store.getState()),
      });

      if (!primed) {
        primed = true;
        session.refreshOffers(accountId);
      }

      return result;
    };
  };
}
