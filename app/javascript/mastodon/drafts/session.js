import {
  COMPOSE_EDIT_CANCEL,
  COMPOSE_QUOTE_CANCEL,
  COMPOSE_REPLY_CANCEL,
  COMPOSE_RESET,
  COMPOSE_SCHEDULED_EDIT_CANCEL,
  COMPOSE_SET_STATUS,
  COMPOSE_SUBMIT_FAIL,
  COMPOSE_SUBMIT_REQUEST,
  COMPOSE_SUBMIT_SUCCESS,
  COMPOSE_UNMOUNT,
  SCHEDULED_STATUS_SUBMIT_SUCCESS,
} from '../actions/compose';
import { COMPOSER_DESTROY, COMPOSER_DRAFT_RESTORE } from '../actions/composer';
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

const EXPLICIT_DISCARD = new Set([
  COMPOSE_EDIT_CANCEL,
  COMPOSE_QUOTE_CANCEL,
  COMPOSE_REPLY_CANCEL,
  COMPOSE_RESET,
  COMPOSE_SCHEDULED_EDIT_CANCEL,
  COMPOSE_REDAFT_DISCARD,
]);

const PUBLISH_SUCCESS = new Set([
  COMPOSE_SUBMIT_SUCCESS,
  SCHEDULED_STATUS_SUBMIT_SUCCESS,
]);

const FORCE_SYNC = new Set([
  COMPOSE_EDIT_CANCEL,
  COMPOSE_QUOTE_CANCEL,
  COMPOSE_REPLY_CANCEL,
  COMPOSE_RESET,
  COMPOSE_SCHEDULED_EDIT_CANCEL,
  COMPOSE_SET_STATUS,
  COMPOSE_SUBMIT_FAIL,
  COMPOSE_SUBMIT_REQUEST,
  COMPOSE_SUBMIT_SUCCESS,
  COMPOSE_UNMOUNT,
  SCHEDULED_STATUS_SUBMIT_SUCCESS,
  COMPOSER_DESTROY,
  COMPOSER_DRAFT_RESTORE,
  REDRAFT,
  COMPOSE_REDAFT_DISCARD,
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
  const publishing = new Map();
  const pending = new Map();
  const writeChains = new Map();
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

  function submitInFlight (clientDraftUuid) {
    let inFlight = false;

    publishing.forEach((record) => {
      if (record.uuid === clientDraftUuid && !record.failed) {
        inFlight = true;
      }
    });

    return inFlight;
  }

  function publishReserved (clientDraftUuid) {
    let reserved = false;

    publishing.forEach((record) => {
      if (record.uuid === clientDraftUuid) {
        reserved = true;
      }
    });

    return reserved;
  }

  function separateHeldDraft (accountId, clientDraftUuid, retiringComposerId) {
    const holders = [];

    surfaces.forEach((surface) => {
      if (surface.clientDraftUuid === clientDraftUuid && surface.composerId !== retiringComposerId) {
        holders.push(surface);
      }
    });

    holders.forEach((surface) => {
      const nextUuid = createId();
      const queued = pending.get(surface.composerId);
      let snapshot = null;

      if (queued && queued.snapshot.client_draft_uuid === clientDraftUuid) {
        snapshot = {
          ...queued.snapshot,
          client_draft_uuid: nextUuid,
        };
      } else if (surface.stateRef) {
        snapshot = snapshotComposerDraft(surface.stateRef, {
          accountId,
          clientDraftUuid: nextUuid,
          composerId: surface.composerId,
          savedAt: now(),
        });
      }

      claimed.delete(clientDraftUuid);
      surface.clientDraftUuid = nextUuid;
      surface.baseRevision = 0;
      surface.lastHash = null;
      surface.scheduledHash = null;
      claimed.set(nextUuid, surface.composerId);
      discarded.delete(nextUuid);

      if (!snapshot) {
        const timer = timers.get(surface.composerId);

        if (timer) {
          cancel(timer);
          timers.delete(surface.composerId);
        }

        pending.delete(surface.composerId);
        return;
      }

      surface.scheduledHash = snapshot.content_hash;
      scheduleWrite(accountId, surface.composerId, snapshot);
    });
  }

  function retireDraft (accountId, composerId, clientDraftUuid, expected) {
    if (!clientDraftUuid) {
      return Promise.resolve();
    }

    // Another composer may already be editing this id. Move that edit to a
    // new id before the sent id is discarded.
    separateHeldDraft(accountId, clientDraftUuid, composerId);
    discarded.add(clientDraftUuid);

    const surface = surfaces.get(composerId);
    const queued = pending.get(composerId);
    const ownsCurrent = Boolean(surface && surface.clientDraftUuid === clientDraftUuid);

    // A newer draft on this composer has its own epoch and write. Retiring
    // the draft that was sent must not make that newer write look stale.
    if (ownsCurrent) {
      epochs.set(composerId, (epochs.get(composerId) || 0) + 1);
      detach(surface);
    } else {
      claimed.delete(clientDraftUuid);

      if (queued && queued.snapshot.client_draft_uuid === clientDraftUuid) {
        const timer = timers.get(composerId);

        if (timer) {
          cancel(timer);
          timers.delete(composerId);
        }

        pending.delete(composerId);
      }
    }

    const previous = writeChains.get(composerId) || Promise.resolve();
    const run = previous.then(
      () => backend.deleteDraft(accountId, clientDraftUuid, expected),
      () => backend.deleteDraft(accountId, clientDraftUuid, expected),
    ).then(() => {
      refreshOffers(accountId);
    }, () => undefined);

    writeChains.set(composerId, run.then(() => undefined, () => undefined));

    return run;
  }

  function discard (accountId, surface) {
    const clientDraftUuid = surface.clientDraftUuid;

    if (!clientDraftUuid) {
      detach(surface);
      return;
    }

    retireDraft(accountId, surface.composerId, clientDraftUuid);
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
      const latest = current && current.clientDraftUuid === snapshot.client_draft_uuid && epochs.get(composerId) === epoch;

      if (latest) {
        current.lastHash = null;
        setPersistence(composerId, 'failed', failure.reason, snapshot.media_incomplete);
      }

      return failure;
    }

    const current = surfaces.get(composerId);
    const ownsUuid = Boolean(current && current.clientDraftUuid === snapshot.client_draft_uuid);
    const latest = ownsUuid && epochs.get(composerId) === epoch;

    if (result.status === 'conflict' && !forked) {
      if (!latest) {
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

    if ((result.status === 'saved' || result.status === 'unchanged') && ownsUuid && result.record) {
      current.baseRevision = result.record.revision;

      if (latest) {
        current.lastHash = snapshot.content_hash;
        setPersistence(composerId, 'saved', null, snapshot.media_incomplete);
      }
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

    const previous = writeChains.get(composerId) || Promise.resolve();
    const run = previous.then(
      () => commit(queued.accountId, composerId, queued.snapshot, queued.epoch),
      () => commit(queued.accountId, composerId, queued.snapshot, queued.epoch),
    );

    writeChains.set(composerId, run.then(() => undefined, () => undefined));

    return run;
  }

  function scheduleWrite (accountId, composerId, snapshot) {
    const epoch = (epochs.get(composerId) || 0) + 1;

    epochs.set(composerId, epoch);
    pending.set(composerId, { accountId, snapshot, epoch });
    setPersistence(composerId, 'saving', null, snapshot.media_incomplete);

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
        && !claimed.has(restored.snapshot.client_draft_uuid)
        && !discarded.has(restored.snapshot.client_draft_uuid)
        && !submitInFlight(restored.snapshot.client_draft_uuid);
    }).map(record => {
      const input = record.input || {};
      const surface = input.surface || null;

      return {
        client_draft_uuid: String(record.client_draft_uuid),
        account_id: String(record.account_id),
        saved_at: record.saved_at || null,
        composer_id: record.composer_id || null,
        media_incomplete: record.media_incomplete === true,
        revision: record.revision || 0,
        surface_kind: surface && surface.kind ? String(surface.kind) : null,
        surface_key: surface && surface.key ? String(surface.key) : null,
        in_reply_to: Boolean(input.in_reply_to_id),
        quote: Boolean(input.quote_id),
      };
    }).sort((left, right) => String(right.saved_at || '').localeCompare(String(left.saved_at || '')));

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
    const reserved = publishReserved(snapshot.client_draft_uuid);
    let clientDraftUuid = snapshot.client_draft_uuid;
    let baseRevision = Number(action.baseRevision) || 0;

    if (reserved) {
      clientDraftUuid = createId();
      baseRevision = 0;
    }

    surface.latched = null;
    surface.clientDraftUuid = clientDraftUuid;
    surface.baseRevision = baseRevision;
    surface.lastHash = reserved ? null : (snapshot.content_hash || null);
    surface.scheduledHash = null;
    claimed.set(clientDraftUuid, composerId);

    if (!reserved) {
      discarded.delete(clientDraftUuid);
    }

    if (!reserved) {
      setPersistence(composerId, 'saved', null, snapshot.media_incomplete === true);
      refreshOffers(snapshot.account_id);
      return;
    }

    const stored = snapshotComposerDraft(state, {
      accountId: snapshot.account_id,
      clientDraftUuid,
      composerId,
      savedAt: now(),
    });

    if (!stored) {
      setPersistence(composerId, 'saved', null, snapshot.media_incomplete === true);
      refreshOffers(snapshot.account_id);
      return;
    }

    surface.scheduledHash = stored.content_hash;
    scheduleWrite(snapshot.account_id, composerId, stored);
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

      if (submitInFlight(clientDraftUuid) && owner !== composerId) {
        return false;
      }

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

      const runs = composerIds.map(composerId => flushComposer(composerId));
      const chains = [];

      writeChains.forEach((chain) => {
        chains.push(chain);
      });

      return Promise.all(runs.concat(chains));
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

      const markSubmitFailed = (composerId, failAction) => {
        const submission = {
          submitId: failAction && (failAction.submitId || (failAction.submission && failAction.submission.submitId)) || null,
          instanceId: failAction && failAction.submission && failAction.submission.instanceId || null,
          token: failAction && failAction.submission && failAction.submission.token || null,
        };
        const records = [];

        publishing.forEach((record, key) => {
          if (record.composerId === composerId) {
            records.push({ key, record });
          }
        });

        let matched = records.filter(({ record }) => submissionMatches(record, submission));

        if (submission.submitId) {
          const bySubmit = matched.filter(({ record }) => record.submitId === submission.submitId);

          if (bySubmit.length > 0) {
            matched = bySubmit;
          }
        }

        if (matched.length === 1) {
          matched[0].record.failed = true;
          refreshOffers(accountId);
        }
      };

      const mediaIdsOf = (state) => {
        const media = state && state.get('media_attachments');

        return media && media.map ? media.map(item => String(item.get('id'))).join('\u001f') : '';
      };

      const keptEditAfterPublish = (state, action, sent) => {
        if (!state || draftCaptureBlock(state)) {
          return false;
        }

        const editing = composerDraftInProgress(state) || String(state.get('spoiler_text') || '').trim() !== '';

        if (!editing) {
          return false;
        }

        const snapshot = snapshotComposerDraft(state, {
          accountId,
          clientDraftUuid: 'pending',
          composerId: 'pending',
          savedAt: now(),
        });

        if (!snapshot) {
          return false;
        }

        if (sent && sent.hash && snapshot.content_hash === sent.hash) {
          return false;
        }

        const submission = action && action.submission;

        if ((!sent || !sent.hash) && submission && (state.get('text') || '') === (submission.text || '') && mediaIdsOf(state) === (submission.mediaIds || '')) {
          return false;
        }

        return true;
      };

      const publishRecordKey = (record) => [
        record.composerId,
        record.submitId || '',
        record.instanceId || '',
        record.token || '',
      ].join('\u0000');

      const submissionMatches = (record, submission) => {
        if (!submission) {
          return false;
        }

        if (record.submitId && submission.submitId && record.submitId !== submission.submitId) {
          return false;
        }

        if (record.instanceId && submission.instanceId && record.instanceId !== submission.instanceId) {
          return false;
        }

        if (record.token && submission.token && record.token !== submission.token) {
          return false;
        }

        return Boolean(
          (record.submitId && submission.submitId)
          || (record.instanceId && submission.instanceId)
          || (record.token && submission.token),
        );
      };

      const takeSentDraft = (composerId, submission) => {
        const records = [];

        publishing.forEach((record, key) => {
          if (record.composerId === composerId) {
            records.push({ key, record });
          }
        });

        const identified = Boolean(submission && (submission.submitId || submission.instanceId || submission.token));

        if (!identified) {
          return { record: null, tracked: false };
        }

        let matched = records.filter(({ record }) => submissionMatches(record, submission));

        if (submission.submitId) {
          const bySubmit = matched.filter(({ record }) => record.submitId === submission.submitId);

          if (bySubmit.length > 0) {
            matched = bySubmit;
          }
        }

        if (matched.length === 1) {
          publishing.delete(matched[0].key);
          return { record: matched[0].record, tracked: true };
        }

        if (records.length > 0) {
          return { record: null, tracked: true };
        }

        return { record: null, tracked: false };
      };

      const sentExpectation = (sent) => {
        if (!sent || !sent.hash) {
          return null;
        }

        return {
          contentHash: sent.hash,
          savedHash: sent.savedHash || null,
          revision: sent.revision === null || sent.revision === undefined ? null : sent.revision,
        };
      };

      const legacySentUuid = (surface, submission) => {
        if (!surface || !surface.clientDraftUuid) {
          return null;
        }

        if (submission && submission.instanceId && surface.instanceId && submission.instanceId !== surface.instanceId) {
          return null;
        }

        return surface.clientDraftUuid;
      };

      const rememberPublishing = (composerId, state, requestAction) => {
        const live = surfaces.get(composerId);

        if (!live || !live.clientDraftUuid || live.instanceId !== state.get('instanceId')) {
          return;
        }

        const snapshot = snapshotComposerDraft(state, {
          accountId,
          clientDraftUuid: live.clientDraftUuid,
          composerId,
          savedAt: now(),
        });
        const record = {
          composerId,
          uuid: live.clientDraftUuid,
          hash: snapshot ? snapshot.content_hash : null,
          savedHash: live.lastHash || null,
          submitId: requestAction && requestAction.submitId || null,
          instanceId: state.get('instanceId') || null,
          token: state.get('idempotencyKey') || null,
          revision: Number(live.baseRevision) || 0,
        };

        publishing.set(publishRecordKey(record), record);
      };

      const finishPublishedDraft = (publishAccountId, composerId, state, publishAction, surface, instanceId) => {
        const submission = publishAction && publishAction.submission;
        const taken = takeSentDraft(composerId, submission);
        const sent = taken.record;
        const sentUuid = (sent && sent.uuid) || (!taken.tracked && legacySentUuid(surface, submission)) || null;
        const currentUuid = surface && surface.clientDraftUuid;

        if (!sentUuid) {
          if (surface) {
            surface.stateRef = state;
          }

          return;
        }

        if (sentUuid) {
          retireDraft(publishAccountId, composerId, sentUuid, sentExpectation(sent));
        }

        let current = surfaces.get(composerId);

        if (currentUuid && sentUuid && currentUuid !== sentUuid) {
          if (current) {
            current.stateRef = state;
          }

          refreshOffers(publishAccountId);
          return;
        }

        if (!current || current.instanceId !== instanceId) {
          current = blankSurface(composerId, instanceId);
          surfaces.set(composerId, current);
        }

        current.stateRef = state;
        current.latched = null;

        if (!keptEditAfterPublish(state, publishAction, sent)) {
          setPersistence(composerId, 'idle', null, false);
          refreshOffers(publishAccountId);
          return;
        }

        const snapshot = snapshotComposerDraft(state, {
          accountId: publishAccountId,
          clientDraftUuid: 'pending',
          composerId,
          savedAt: now(),
        });

        if (!snapshot) {
          setPersistence(composerId, 'idle', null, false);
          refreshOffers(publishAccountId);
          return;
        }

        current.clientDraftUuid = createId();
        current.baseRevision = 0;
        current.lastHash = null;
        claimed.set(current.clientDraftUuid, composerId);

        const stored = {
          ...snapshot,
          client_draft_uuid: current.clientDraftUuid,
        };

        current.scheduledHash = stored.content_hash;
        scheduleWrite(publishAccountId, composerId, stored);
        refreshOffers(publishAccountId);
      };

      if (type === COMPOSE_SUBMIT_FAIL) {
        markSubmitFailed(actionComposerId(action), action);
      }

      (composers || []).forEach(({ composerId, state }) => {
        if (!state || typeof state.get !== 'function') {
          return;
        }

        seen.add(composerId);

        let surface = surfaces.get(composerId);
        const targeted = actionComposerId(action) === composerId;

        try {
          if (surface && surface.stateRef === state && !(targeted && FORCE_SYNC.has(type))) {
            return;
          }

          if (targeted && PUBLISH_SUCCESS.has(type)) {
            finishPublishedDraft(accountId, composerId, state, action, surface, state.get('instanceId'));
            return;
          }

          const instanceId = state.get('instanceId');

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

          surface.stateRef = state;

          if (type === COMPOSER_DRAFT_RESTORE && actionComposerId(action) === composerId) {
            adoptRestored(composerId, state, action);
            return;
          }

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

          if (surface.latched || blocked) {
            flushComposer(composerId);
            const released = Boolean(surface.clientDraftUuid);

            detach(surface);

            if (released) {
              refreshOffers(accountId);
            }

            return;
          }

          let discardedCurrent = false;

          if (targeted && EXPLICIT_DISCARD.has(type) && surface.clientDraftUuid) {
            discard(accountId, surface);
            discardedCurrent = true;
            refreshOffers(accountId);
          }

          const snapshot = snapshotComposerDraft(state, {
            accountId,
            clientDraftUuid: surface.clientDraftUuid || 'pending',
            composerId,
            savedAt: now(),
          });

          if (!snapshot) {
            if (discardedCurrent) {
              setPersistence(composerId, 'idle', null, false);
            } else if (surface.clientDraftUuid) {
              flushComposer(composerId);
              detach(surface);
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
        } finally {
          if (targeted && type === COMPOSE_SUBMIT_REQUEST) {
            rememberPublishing(composerId, state, action);
          }
        }
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

        if (PUBLISH_SUCCESS.has(type) && actionComposerId(action) === composerId) {
          const submission = action && action.submission;
          const taken = takeSentDraft(composerId, submission);
          const uuid = (taken.record && taken.record.uuid) || (!taken.tracked && legacySentUuid(surface, submission));

          if (uuid) {
            retireDraft(accountId, composerId, uuid, sentExpectation(taken.record));
          }

          surfaces.delete(composerId);
          refreshOffers(accountId);
          return;
        }

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

      if (PUBLISH_SUCCESS.has(type)) {
        const target = actionComposerId(action);

        if (!seen.has(target) && !surfaces.has(target)) {
          const taken = takeSentDraft(target, action && action.submission);
          const uuid = taken.record && taken.record.uuid;

          if (uuid) {
            retireDraft(accountId, target, uuid, sentExpectation(taken.record));
          }
        }
      }
    },
  };
}
