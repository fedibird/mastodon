import {
  COMPOSE_EDIT_CANCEL,
  COMPOSE_RESET,
  COMPOSE_SCHEDULED_EDIT_CANCEL,
  COMPOSE_SET_STATUS,
  COMPOSE_SUBMIT_SUCCESS,
  SCHEDULED_STATUS_SUBMIT_SUCCESS,
} from '../actions/compose';
import { COMPOSER_DRAFT_RESTORE } from '../actions/composer';
import { COMPOSE_REDAFT_DISCARD } from '../actions/redraft_media';
import { REDRAFT } from '../actions/statuses';
import { composerDraftInProgress } from '../posting_context/surface';
import { PRIMARY_COMPOSER_ID } from '../utils/composer';
import uuid from '../uuid';
import { isQuotaError } from './storage';
import {
  draftCaptureBlock,
  restoreComposerDraft,
  snapshotComposerDraft,
} from './snapshot';

const CLEAR_LATCH = new Set([
  COMPOSE_EDIT_CANCEL,
  COMPOSE_RESET,
  COMPOSE_SCHEDULED_EDIT_CANCEL,
  COMPOSE_REDAFT_DISCARD,
]);

const PUBLISH_SUCCESS = new Set([
  COMPOSE_SUBMIT_SUCCESS,
  SCHEDULED_STATUS_SUBMIT_SUCCESS,
]);

function actionComposerId (action) {
  if (action && action.meta && action.meta.composerId) {
    return action.meta.composerId;
  }

  return PRIMARY_COMPOSER_ID;
}

export function createComposerDraftSession ({
  backend,
  now = () => new Date().toISOString(),
  createId = uuid,
  debounceMs = 300,
  schedule = (fn, ms) => setTimeout(fn, ms),
  cancel = (id) => clearTimeout(id),
} = {}) {
  const surfaces = new Map();
  const claimed = new Map();
  const discarded = new Set();
  const pending = new Map();
  const timers = new Map();
  const epochs = new Map();
  const persistence = new Map();
  const listeners = new Set();
  let offers = [];
  let unavailable = false;

  const notify = () => {
    listeners.forEach((listener) => listener());
  };

  const setPersistence = (composerId, status, reason, mediaIncomplete) => {
    const previous = persistence.get(composerId);
    const next = {
      status,
      reason: reason || null,
      mediaIncomplete: mediaIncomplete === true,
    };

    if (previous && previous.status === next.status && previous.reason === next.reason && previous.mediaIncomplete === next.mediaIncomplete) {
      return;
    }

    persistence.set(composerId, next);
    notify();
  };

  const markUnavailable = () => {
    unavailable = true;
    surfaces.forEach((_surface, composerId) => setPersistence(composerId, 'failed', 'unavailable', false));
    notify();
  };

  const fail = (error) => {
    if (error && error.reason === 'unavailable') {
      markUnavailable();
      return { status: 'failed', reason: 'unavailable' };
    }

    return { status: 'failed', reason: isQuotaError(error) ? 'quota' : 'write' };
  };

  function blankSurface (composerId, instanceId) {
    return {
      composerId,
      instanceId,
      clientDraftUuid: null,
      baseRevision: 0,
      latched: null,
      lastHash: null,
      scheduledHash: null,
    };
  }

  function detach (surface) {
    if (surface.clientDraftUuid) {
      claimed.delete(surface.clientDraftUuid);
    }

    surface.clientDraftUuid = null;
    surface.baseRevision = 0;
    surface.lastHash = null;
    surface.scheduledHash = null;
    pending.delete(surface.composerId);
  }

  function discard (accountId, surface) {
    const clientDraftUuid = surface.clientDraftUuid;

    detach(surface);

    if (!clientDraftUuid) {
      return;
    }

    discarded.add(clientDraftUuid);
    epochs.set(surface.composerId, (epochs.get(surface.composerId) || 0) + 1);
    backend.deleteDraft(accountId, clientDraftUuid).catch(() => undefined);
  }

  function writeOptions (composerId, epoch, clientDraftUuid) {
    return {
      baseRevision: (surfaces.get(composerId) || {}).baseRevision || 0,
      stillCurrent: () => epochs.get(composerId) === epoch && !discarded.has(clientDraftUuid),
      isDiscarded: () => discarded.has(clientDraftUuid),
    };
  }

  async function commit (accountId, composerId, snapshot, epoch, forked = false) {
    if (unavailable) {
      setPersistence(composerId, 'failed', 'unavailable', snapshot.media_incomplete);
      return { status: 'failed', reason: 'unavailable' };
    }

    const surface = surfaces.get(composerId);
    const options = writeOptions(composerId, epoch, snapshot.client_draft_uuid);

    if (surface) {
      options.baseRevision = surface.baseRevision || 0;
    }

    let result;

    try {
      result = await backend.writeDraft(snapshot, options);
    } catch (error) {
      const failure = fail(error);
      const current = surfaces.get(composerId);

      if (current) {
        current.lastHash = null;
      }

      setPersistence(composerId, 'failed', failure.reason, snapshot.media_incomplete);
      return failure;
    }

    const current = surfaces.get(composerId);

    if (result.status === 'conflict' && !forked) {
      if (!current || epochs.get(composerId) !== epoch) {
        return result;
      }

      const forkedSnapshot = {
        ...snapshot,
        client_draft_uuid: createId(),
      };

      claimed.delete(snapshot.client_draft_uuid);
      claimed.set(forkedSnapshot.client_draft_uuid, composerId);
      current.clientDraftUuid = forkedSnapshot.client_draft_uuid;
      current.baseRevision = 0;
      current.lastHash = null;
      epochs.set(composerId, epoch + 1);

      return commit(accountId, composerId, forkedSnapshot, epoch + 1, true);
    }

    if ((result.status === 'saved' || result.status === 'unchanged') && current && current.clientDraftUuid === snapshot.client_draft_uuid) {
      current.baseRevision = result.record.revision;
      current.lastHash = snapshot.content_hash;
      setPersistence(composerId, 'saved', null, snapshot.media_incomplete);
    }

    if (result.status === 'saved' || result.status === 'discarded' || result.status === 'conflict') {
      refreshOffers(accountId);
    }

    return result;
  }

  function flushComposer (composerId) {
    const timer = timers.get(composerId);

    if (timer) {
      cancel(timer);
      timers.delete(composerId);
    }

    const queued = pending.get(composerId);

    if (!queued) {
      return Promise.resolve(null);
    }

    pending.delete(composerId);

    return commit(queued.accountId, composerId, queued.snapshot, queued.epoch);
  }

  function scheduleWrite (accountId, composerId, snapshot) {
    const epoch = (epochs.get(composerId) || 0) + 1;

    epochs.set(composerId, epoch);
    pending.set(composerId, { accountId, snapshot, epoch });

    const existing = timers.get(composerId);

    if (existing) {
      cancel(existing);
    }

    timers.set(composerId, schedule(() => {
      timers.delete(composerId);
      flushComposer(composerId);
    }, debounceMs));
  }

  async function refreshOffers (accountId) {
    if (!accountId || unavailable) {
      return offers;
    }

    let records;

    try {
      records = await backend.listDrafts(accountId);
    } catch (error) {
      fail(error);
      return offers;
    }

    const next = (records || []).filter((record) => {
      const restored = restoreComposerDraft(record);

      return restored.ok
        && String(restored.snapshot.account_id) === String(accountId)
        && !claimed.has(restored.snapshot.client_draft_uuid);
    }).map(record => ({
      client_draft_uuid: String(record.client_draft_uuid),
      account_id: String(record.account_id),
      saved_at: record.saved_at || null,
      composer_id: record.composer_id || null,
      media_incomplete: record.media_incomplete === true,
      revision: record.revision || 0,
    })).sort((left, right) => String(right.saved_at || '').localeCompare(String(left.saved_at || '')));

    const same = next.length === offers.length && next.every((item, index) => item.client_draft_uuid === offers[index].client_draft_uuid);

    offers = next;

    if (!same) {
      notify();
    }

    return offers;
  }

  function adoptRestored (composerId, state, action) {
    const surface = surfaces.get(composerId);

    if (!surface || !action.snapshot || state.get('idempotencyKey') !== action.idempotencyKey) {
      return;
    }

    const snapshot = action.snapshot;

    surface.latched = null;
    surface.clientDraftUuid = snapshot.client_draft_uuid;
    surface.baseRevision = Number(action.baseRevision) || 0;
    surface.lastHash = snapshot.content_hash || null;
    claimed.set(snapshot.client_draft_uuid, composerId);
    discarded.delete(snapshot.client_draft_uuid);
    setPersistence(composerId, 'saved', null, snapshot.media_incomplete === true);
    refreshOffers(snapshot.account_id);
  }

  return {
    subscribe (listener) {
      listeners.add(listener);

      return () => listeners.delete(listener);
    },

    snapshot () {
      const byComposer = {};

      persistence.forEach((value, composerId) => {
        byComposer[composerId] = value;
      });

      return {
        offers: offers.slice(),
        persistence: byComposer,
        unavailable,
      };
    },

    claim (clientDraftUuid, composerId) {
      if (!clientDraftUuid) {
        return false;
      }

      const owner = claimed.get(clientDraftUuid);

      if (owner && owner !== composerId) {
        return false;
      }

      claimed.set(clientDraftUuid, composerId);

      return true;
    },

    release (clientDraftUuid) {
      claimed.delete(clientDraftUuid);
    },

    read (accountId, clientDraftUuid) {
      return backend.readDraft(accountId, clientDraftUuid);
    },

    refreshOffers,

    flush () {
      const composerIds = [];

      pending.forEach((_value, composerId) => {
        composerIds.push(composerId);
      });

      return Promise.all(composerIds.map(composerId => flushComposer(composerId)));
    },

    bindLifecycle (target) {
      if (!target || typeof target.addEventListener !== 'function') {
        return () => undefined;
      }

      const onHide = () => {
        this.flush();
      };
      const onVisibility = () => {
        if (target.visibilityState === 'hidden') {
          this.flush();
        }
      };

      target.addEventListener('pagehide', onHide);
      target.addEventListener('visibilitychange', onVisibility);

      return () => {
        target.removeEventListener('pagehide', onHide);
        target.removeEventListener('visibilitychange', onVisibility);
      };
    },

    sync ({ accountId, action, composers }) {
      if (!accountId) {
        return;
      }

      const type = action && action.type;
      const seen = new Set();

      (composers || []).forEach(({ composerId, state }) => {
        if (!state || typeof state.get !== 'function') {
          return;
        }

        seen.add(composerId);
        const instanceId = state.get('instanceId');
        let surface = surfaces.get(composerId);

        if (surface && surface.instanceId !== instanceId) {
          flushComposer(composerId);

          if (surface.clientDraftUuid) {
            claimed.delete(surface.clientDraftUuid);
          }

          surface = null;
          refreshOffers(accountId);
        }

        if (!surface) {
          surface = blankSurface(composerId, instanceId);
          surfaces.set(composerId, surface);
        }

        if (type === COMPOSER_DRAFT_RESTORE && actionComposerId(action) === composerId) {
          adoptRestored(composerId, state, action);
          return;
        }

        const targeted = actionComposerId(action) === composerId;

        if (targeted && type === REDRAFT) {
          surface.latched = 'redraft';
        }

        if (targeted && type === COMPOSE_SET_STATUS) {
          surface.latched = 'existing_edit';
        }

        const blocked = draftCaptureBlock(state);

        if (blocked) {
          surface.latched = surface.latched || blocked;
        }

        if (targeted && CLEAR_LATCH.has(type) && !blocked) {
          surface.latched = null;
        }

        if (targeted && PUBLISH_SUCCESS.has(type) && !composerDraftInProgress(state)) {
          discard(accountId, surface);
          setPersistence(composerId, 'idle', null, false);
          refreshOffers(accountId);
          return;
        }

        if (surface.latched || blocked) {
          flushComposer(composerId);
          const released = Boolean(surface.clientDraftUuid);

          detach(surface);

          if (released) {
            refreshOffers(accountId);
          }

          return;
        }

        const snapshot = snapshotComposerDraft(state, {
          accountId,
          clientDraftUuid: surface.clientDraftUuid || 'pending',
          composerId,
          savedAt: now(),
        });

        if (!snapshot) {
          if (surface.clientDraftUuid) {
            discard(accountId, surface);
            setPersistence(composerId, 'idle', null, false);
            refreshOffers(accountId);
          }

          return;
        }

        if (!surface.clientDraftUuid) {
          surface.clientDraftUuid = createId();
          surface.baseRevision = 0;
          claimed.set(surface.clientDraftUuid, composerId);
        }

        const storedSnapshot = {
          ...snapshot,
          client_draft_uuid: surface.clientDraftUuid,
        };

        if (storedSnapshot.content_hash === surface.lastHash) {
          return;
        }

        if (storedSnapshot.content_hash === surface.scheduledHash && pending.has(composerId)) {
          return;
        }

        surface.scheduledHash = storedSnapshot.content_hash;
        scheduleWrite(accountId, composerId, storedSnapshot);
      });

      let releasedSurface = false;
      const surfaceIds = [];

      surfaces.forEach((_surface, composerId) => {
        surfaceIds.push(composerId);
      });

      surfaceIds.forEach((composerId) => {
        if (seen.has(composerId)) {
          return;
        }

        const surface = surfaces.get(composerId);

        flushComposer(composerId);

        if (surface && surface.clientDraftUuid) {
          claimed.delete(surface.clientDraftUuid);
          releasedSurface = true;
        }

        surfaces.delete(composerId);
      });

      if (releasedSurface) {
        refreshOffers(accountId);
      }
    },
  };
}
