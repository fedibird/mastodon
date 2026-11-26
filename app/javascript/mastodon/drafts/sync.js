// Server sync for a local composer draft. IndexedDB stays the copy that
// survives a reload. A server acknowledgement counts only when its payload
// hash is the hash of the edit that is current now.
//
// Publishing a post must not delete the server draft. #804 decides how a
// server draft is consumed. An explicit discard deletes it only at a
// revision this page acknowledged from a direct success response. A lost
// response stays unknown and is not deleted from a later lookup.
//
import { sameSyncBase, transitionSyncCursor } from './storage';

// A 409 does not copy the draft. #811 allows one media id on one server
// draft, so a second server draft cannot reuse those ids. The local text,
// settings, and media references stay. A later step can copy the text and
// settings under a new client_uuid and ask for the files again.

export const SERVER_DEBOUNCE_MS = 2000;
export const SERVER_RETRY_LIMIT = 5;
export const SERVER_RETRY_BASE_MS = 1000;
export const SERVER_RETRY_CAP_MS = 16000;
export const SERVER_MAX_IN_FLIGHT = 2;
export const SERVER_PAYLOAD_MAX_BYTES = 262144;

export const SERVER_DRAFT_CONFLICT_COPY = Object.freeze({
  available: false,
  sharesMediaIds: false,
  unlinksMedia: false,
  keepsLocalText: true,
  keepsLocalSettings: true,
  keepsLocalMediaReferences: true,
  nextStep: 'reattach_media_under_a_new_client_uuid',
});

const PAYLOAD_KEYS = [
  'schema_version',
  'composer_id',
  'media_incomplete',
  'content_hash',
  'input',
  'account_id',
  'client_draft_uuid',
  'saved_at',
];

export function serverDraftPayload (snapshot) {
  const payload = {};

  if (!snapshot || typeof snapshot !== 'object') {
    return payload;
  }

  PAYLOAD_KEYS.forEach((key) => {
    if (Object.prototype.hasOwnProperty.call(snapshot, key)) {
      payload[key] = snapshot[key];
    }
  });

  return payload;
}

function sortValue (value) {
  if (Array.isArray(value)) {
    return value.map(sortValue);
  }

  if (value && typeof value === 'object') {
    const sorted = {};

    Object.keys(value).sort().forEach((key) => {
      if (value[key] !== undefined) {
        sorted[key] = sortValue(value[key]);
      }
    });

    return sorted;
  }

  return value;
}

export function canonicalJson (value) {
  return JSON.stringify(sortValue(value));
}

function structuralSeparators (json) {
  let count = 0;
  let inString = false;
  let escape = false;

  for (let index = 0; index < json.length; index += 1) {
    const char = json[index];

    if (inString) {
      if (escape) {
        escape = false;
      } else if (char === '\\') {
        escape = true;
      } else if (char === '"') {
        inString = false;
      }
    } else if (char === '"') {
      inString = true;
    } else if (char === ':' || char === ',') {
      count += 1;
    }
  }

  return count;
}

function utf8Bytes (text) {
  if (typeof TextEncoder !== 'undefined') {
    return new TextEncoder().encode(text).length;
  }

  return text.length;
}

// Same estimate as PostDrafts::Payload.stored_text_bytes: compact JSON plus
// one byte for each structural separator PostgreSQL jsonb inserts.
export function storedPayloadBytes (value) {
  const json = canonicalJson(value);

  return utf8Bytes(json) + structuralSeparators(json);
}

export function createSyncLedgerState () {
  return {
    rows: new Map(),
    chain: Promise.resolve(),
  };
}

export function createMemorySyncLedger (state = createSyncLedgerState()) {
  const rows = state.rows;
  const keyFor = (accountId, clientUuid) => `${String(accountId)}\u0000${String(clientUuid)}`;
  const exclusive = (fn) => {
    const run = state.chain.then(fn, fn);

    state.chain = run.then(() => undefined, () => undefined);

    return run;
  };

  return {
    read (accountId, clientUuid) {
      return exclusive(async () => rows.get(keyFor(accountId, clientUuid)) || null);
    },

    commit (accountId, clientUuid, proposed) {
      return exclusive(async () => {
        const key = keyFor(accountId, clientUuid);
        const merged = transitionSyncCursor(rows.get(key) || null, {
          ...(proposed || {}),
          account_id: accountId,
          client_uuid: clientUuid,
        });

        if (merged.accepted !== false) {
          rows.set(key, merged.record);
        }

        return merged;
      });
    },

    write (record) {
      return this.commit(record.account_id, record.client_uuid, record).then(merged => merged.record);
    },

    list (accountId) {
      return exclusive(async () => {
        const matched = [];

        rows.forEach((record) => {
          if (String(record.account_id) === String(accountId)) {
            matched.push({ ...record });
          }
        });

        return matched;
      });
    },
  };
}

function draftResource (body) {
  if (!body || typeof body !== 'object') {
    return null;
  }

  const revision = Number(body.revision);

  if (!body.draft_id || !Number.isInteger(revision) || revision < 1) {
    return null;
  }

  const payload = body.payload && typeof body.payload === 'object' ? body.payload : null;

  return {
    draftId: String(body.draft_id),
    revision,
    hash: payload && payload.content_hash ? String(payload.content_hash) : null,
    updatedAt: body.updated_at || null,
  };
}

function failureKind (response) {
  const status = response ? response.status : 0;
  const body = response && response.body;

  if (status === 401 || status === 403) {
    return 'scope';
  }

  if (status === 409) {
    return 'conflict';
  }

  if (status === 404) {
    return 'missing';
  }

  if (status === 422 || status === 413) {
    if (body && body.code === 'limit_reached') {
      return 'limit';
    }

    const errors = body && body.errors;

    if (Array.isArray(errors) && errors.some(item => item && item.code === 'too_large')) {
      return 'too_large';
    }

    return 'invalid';
  }

  if (status >= 500 || status === 0 || (response && response.timedOut)) {
    return 'retry';
  }

  return 'retry';
}

export function createPostDraftSync ({
  request,
  ledger = createMemorySyncLedger(),
  serverDebounceMs = SERVER_DEBOUNCE_MS,
  maxAttempts = SERVER_RETRY_LIMIT,
  retryBaseMs = SERVER_RETRY_BASE_MS,
  retryCapMs = SERVER_RETRY_CAP_MS,
  maxInFlight = SERVER_MAX_IN_FLIGHT,
  payloadMaxBytes = SERVER_PAYLOAD_MAX_BYTES,
  schedule = (fn, ms) => setTimeout(fn, ms),
  cancel = (id) => clearTimeout(id),
  online = () => (typeof navigator === 'undefined' ? true : navigator.onLine !== false),
  subscribeOnline = (listener) => {
    if (typeof window === 'undefined' || typeof window.addEventListener !== 'function') {
      return () => undefined;
    }

    window.addEventListener('online', listener);

    return () => window.removeEventListener('online', listener);
  },
  ownerId = `page-${Math.random().toString(16).slice(2)}`,
  onAcknowledged,
} = {}) {
  let operationSeq = 0;
  const jobs = new Map();
  const chains = new Map();
  const listeners = new Set();
  let bound = null;
  let epoch = 0;
  let protection = 'pending';
  let protectionTicket = 0;
  let readyResolve = () => undefined;
  let readyPromise = Promise.resolve();
  let inFlight = 0;
  const slotWaiters = [];
  let unavailable = false;

  function emit () {
    listeners.forEach((listener) => {
      try {
        listener();
      } catch (_error) {
        // A listener cannot stop the sync state machine.
      }
    });
  }

  const unsubscribeOnline = subscribeOnline(() => {
    jobs.forEach((job) => {
      if (!job.waitingOnline || job.conflict) {
        return;
      }

      job.waitingOnline = false;

      if (job.tombstone) {
        scheduleDelete(job, 0);
      } else {
        scheduleJob(job, 0);
      }
    });
  });

  function serial (clientUuid, fn) {
    const previous = chains.get(clientUuid) || Promise.resolve();
    const run = previous.then(fn, fn);

    chains.set(clientUuid, run.then(() => undefined, () => undefined));

    return run;
  }

  function acquire () {
    if (inFlight < maxInFlight) {
      inFlight += 1;
      return Promise.resolve();
    }

    return new Promise((resolve) => {
      slotWaiters.push(() => {
        inFlight += 1;
        resolve();
      });
    });
  }

  function release () {
    inFlight -= 1;
    const next = slotWaiters.shift();

    if (next) {
      next();
    }
  }

  function ensureJob (clientUuid) {
    const key = String(clientUuid);
    let job = jobs.get(key);

    if (!job) {
      job = {
        accountId: bound,
        clientUuid: key,
        editGeneration: 0,
        localRevision: 0,
        contentHash: null,
        payload: null,
        serverDraftId: null,
        serverRevision: null,
        ackedHash: null,
        ackedGeneration: null,
        ackedRevision: null,
        cursorVersion: 0,
        deleteRevision: null,
        deleteDraftId: null,
        syncGeneration: 0,
        pageSession: null,
        pageEpoch: 0,
        conflict: false,
        conflictRevision: null,
        deleteState: null,
        probeHash: null,
        pendingHash: null,
        pendingDirty: false,
        observed: false,
        status: 'local',
        reason: null,
        tombstone: false,
        hold: false,
        attempts: 0,
        timer: null,
        running: false,
        sendingHash: null,
        sendingGeneration: null,
        waitingOnline: false,
      };
      jobs.set(key, job);
    }

    return job;
  }

  function acceptPageEdit (job, input) {
    const sessionId = input.sessionId ? String(input.sessionId) : 'draft-sync';
    const pageEpoch = Number(input.editGeneration) || 0;

    if (job.pageSession === sessionId && pageEpoch < job.pageEpoch) {
      return false;
    }

    job.pageSession = sessionId;
    job.pageEpoch = pageEpoch;

    return true;
  }

  function bumpSyncGeneration (job, hash) {
    if (hash && hash !== job.contentHash) {
      job.syncGeneration = (Number(job.syncGeneration) || 0) + 1;
    } else if (!job.syncGeneration) {
      job.syncGeneration = 1;
    }

    job.editGeneration = job.syncGeneration;
  }

  function clearTimer (job) {
    if (job.timer) {
      cancel(job.timer);
      job.timer = null;
    }
  }

  function networkAllowed (job) {
    return protection === 'ready' && !unavailable && job && !job.stopped && !job.durabilityStop && !job.conflict && !job.tombstone && !job.unbased;
  }

  function deleteAllowed (job, sentEpoch) {
    return current(job, sentEpoch)
      && protection === 'ready'
      && !unavailable
      && !job.stopped
      && !job.durabilityStop
      && !job.hold
      && !job.conflict
      && !(job.intent && job.intent.unresolved)
      && job.tombstone
      && job.deleteState === 'pending'
      && job.ackDirect === true
      && job.deleteRevision
      && job.deleteDraftId
      && Number(job.ackedRevision) === Number(job.deleteRevision);
  }

  function scheduleJob (job, delay) {
    if (!networkAllowed(job) || job.hold || job.running) {
      return;
    }

    clearTimer(job);
    job.timer = schedule(() => {
      job.timer = null;
      serial(job.clientUuid, () => push(job));
    }, delay);
  }

  function scheduleDelete (job, delay) {
    if (protection !== 'ready' || !job || job.stopped || !job.tombstone || job.conflict || job.deleteState === 'deleted' || job.deleteState === 'blocked') {
      return;
    }

    clearTimer(job);
    job.timer = schedule(() => {
      job.timer = null;
      serial(job.clientUuid, () => continueDiscard(job, epoch));
    }, delay);
  }

  function cursorFrom (job, extra) {
    const fields = extra || {};

    return {
      account_id: job.accountId,
      client_uuid: job.clientUuid,
      server_draft_id: fields.serverDraftId === undefined ? job.serverDraftId : fields.serverDraftId,
      server_revision: fields.serverRevision === undefined ? job.ackedRevision : fields.serverRevision,
      acked_hash: fields.ackedHash === undefined ? job.ackedHash : fields.ackedHash,
      acked_generation: fields.ackedGeneration === undefined ? job.ackedGeneration : fields.ackedGeneration,
      sync_generation: fields.syncGeneration === undefined ? job.syncGeneration : fields.syncGeneration,
      conflict: fields.conflict === undefined ? job.conflict === true : fields.conflict === true,
      conflict_revision: fields.conflictRevision === undefined ? job.conflictRevision : fields.conflictRevision,
      delete_state: fields.deleteState === undefined ? job.deleteState : fields.deleteState,
      probe_hash: fields.probeHash === undefined ? job.probeHash : fields.probeHash,
      intent_kind: job.intent ? job.intent.kind : null,
      intent_hash: job.intent ? job.intent.hash : null,
      intent_base_revision: job.intent ? job.intent.baseRevision : null,
      intent_expected_revision: job.intent ? job.intent.expectedRevision : null,
      intent_draft_id: job.intent ? job.intent.draftId : null,
      intent_state: job.intent ? job.intent.state : null,
      operation_id: job.intent ? job.intent.id : null,
      operation_owner: job.intent ? job.intent.owner : null,
      delete_revision: fields.deleteRevision === undefined ? job.deleteRevision : fields.deleteRevision,
      delete_draft_id: fields.deleteDraftId === undefined ? job.deleteDraftId : fields.deleteDraftId,
      tombstone: fields.tombstone === undefined ? job.tombstone === true : fields.tombstone === true,
      transition: fields.transition,
      cursor_version: fields.cursorVersion === undefined ? job.cursorVersion : fields.cursorVersion,
    };
  }

  function intentFrom (record) {
    if (!record || !record.intent_kind) {
      return null;
    }

    return {
      id: record.operation_id || null,
      owner: record.operation_owner || null,
      kind: record.intent_kind,
      hash: record.intent_hash || null,
      baseRevision: positiveOrNull(record.intent_base_revision),
      expectedRevision: positiveOrNull(record.intent_expected_revision),
      draftId: record.intent_draft_id || null,
      state: record.intent_state === 'unknown' ? 'unknown' : 'open',
      unresolved: true,
    };
  }

  function adoptCommit (job, merged) {
    const record = merged && merged.record;

    if (!record) {
      return;
    }

    job.cursorVersion = Number(record.cursor_version) || 0;
    job.deleteState = record.delete_state || job.deleteState;
    job.blockedByLedger = merged.blocked === true || record.tombstone === true || record.conflict === true;
    job.intentHeld = merged.heldIntent === true || merged.reason === 'intent_held' || merged.reason === 'unknown';

    if (record.tombstone) {
      job.tombstone = true;
    }

    if (record.conflict) {
      job.conflict = true;
      job.conflictRevision = record.conflict_revision || job.conflictRevision;
    }

    if (merged.accepted === false) {
      if (merged.reason === 'stale_base' || merged.reason === 'stale_cursor' || merged.reason === 'protected') {
        job.conflict = true;
        job.status = 'conflict';
        job.reason = job.tombstone ? 'discard_blocked' : 'conflict';
      } else if (job.intentHeld) {
        job.status = 'local';
        job.reason = 'intent_held';
      }

      const storedIntent = intentFrom(record);

      if (storedIntent && (!job.intent || storedIntent.id !== job.intent.id)) {
        job.intent = storedIntent;
        job.intentHeld = true;
      }

      return;
    }

    if (record.delete_state === 'deleted') {
      job.serverDraftId = null;
      job.ackedRevision = null;
      job.ackedHash = null;
      job.ackDirect = false;
      job.intent = null;
      job.deleteState = 'deleted';
      job.status = 'deleted';
      job.reason = null;
      return;
    }

    if (!record.intent_kind) {
      job.ackedRevision = record.server_revision || job.ackedRevision;
      job.serverDraftId = record.server_draft_id || job.serverDraftId;
      job.ackedHash = record.acked_hash || job.ackedHash;

      if (merged.reason === 'finished' || merged.reason === 'rejected') {
        job.intent = null;
        job.intentHeld = false;
      }
    } else {
      job.intent = intentFrom(record);
      job.intentHeld = job.intent.owner !== ownerId || job.intent.state === 'unknown' && job.contentHash !== job.intent.hash;
    }

    if (record.delete_revision) {
      job.deleteRevision = record.delete_revision;
      job.deleteDraftId = record.delete_draft_id || job.deleteDraftId;
    }

    if (job.conflict) {
      job.status = 'conflict';
      job.reason = job.tombstone ? 'discard_blocked' : 'conflict';
    }
  }

  function noteRejection (job, merged) {
    const record = merged && merged.record;
    const discarded = job.tombstone || (record && record.tombstone === true);

    job.running = false;

    if (discarded) {
      job.tombstone = true;
      job.deleteState = record && record.delete_state === 'deleted' ? 'deleted' : 'unknown';
      job.ackDirect = job.deleteState === 'deleted';
      job.status = job.deleteState === 'deleted' ? 'deleted' : 'local';
      job.reason = job.deleteState === 'deleted' ? null : 'delete_unknown';
    } else if (job.hold) {
      job.status = 'held';
      job.reason = 'publish';
    } else if (job.status === 'syncing' || job.status === 'synced') {
      job.status = 'local';
      job.reason = 'protected';
    }

    emit();
  }

  function persist (job, extra) {
    if (!extra || !extra.transition) {
      noteRejection(job, null);
      return Promise.resolve('rejected');
    }

    if (!job.accountId || typeof ledger.commit !== 'function') {
      job.durabilityStop = true;
      job.stopped = true;
      job.reason = 'ledger';
      emit();
      return Promise.resolve('stopped');
    }

    return ledger.commit(job.accountId, job.clientUuid, cursorFrom(job, extra)).then((merged) => {
      if (!merged || merged.accepted === false) {
        noteRejection(job, merged);
        return 'rejected';
      }

      const sentHash = job.intent ? job.intent.hash : job.contentHash;
      const previousBase = {
        recorded: true,
        revision: job.intent ? job.intent.baseRevision : null,
        draft_id: job.intent ? job.intent.draftId : null,
        hash: job.ackedHash || null,
      };

      adoptCommit(job, merged);

      if (merged.reason === 'finished') {
        job.verifiedHash = sentHash;
        job.baseVerified = job.contentHash === sentHash && !job.pendingDirty;
        job.unbased = false;
        job.previousBase = previousBase;
        job.syncBase = {
          recorded: true,
          revision: job.ackedRevision,
          draft_id: job.serverDraftId,
          hash: job.ackedHash,
        };

        if (typeof onAcknowledged === 'function') {
          Promise.resolve(onAcknowledged({
            accountId: job.accountId,
            clientUuid: job.clientUuid,
            previous: previousBase,
            next: job.syncBase,
            contentHash: sentHash,
          })).catch(() => undefined);
        }
      }

      return 'accepted';
    }, () => {
      job.durabilityStop = true;
      job.stopped = true;
      job.reason = 'ledger';

      if (job.conflict) {
        job.status = 'conflict';
      } else if (job.tombstone && job.deleteState !== 'deleted') {
        job.deleteState = 'unknown';
        job.status = 'local';
      }

      emit();
      return 'stopped';
    });
  }

  function applyCursor (job, cursor) {
    if (!cursor || String(cursor.account_id) !== String(job.accountId)) {
      return;
    }

    job.serverDraftId = cursor.server_draft_id || job.serverDraftId;
    job.ackedRevision = Number(cursor.server_revision) || job.ackedRevision;
    job.ackedHash = cursor.acked_hash || job.ackedHash;
    job.ackedGeneration = Number(cursor.acked_generation) || job.ackedGeneration;
    job.syncGeneration = Number(cursor.sync_generation) || job.syncGeneration || 0;
    job.editGeneration = job.syncGeneration;
    job.conflict = job.conflict || cursor.conflict === true;
    job.conflictRevision = Number(cursor.conflict_revision) || job.conflictRevision;
    job.deleteState = cursor.delete_state || job.deleteState;
    job.probeHash = cursor.probe_hash || job.probeHash;
    job.tombstone = job.tombstone || cursor.tombstone === true;
    job.cursorVersion = Number(cursor.cursor_version) || job.cursorVersion || 0;
    job.deleteRevision = positiveOrNull(cursor.delete_revision) || job.deleteRevision;
    job.deleteDraftId = cursor.delete_draft_id || job.deleteDraftId;

    if (cursor.server_revision && !cursor.intent_kind) {
      job.ackDirect = true;
    }

    if (cursor.intent_kind) {
      job.intentUnresolved = true;
      job.intent = intentFrom(cursor);
    }
  }

  function resumeMode (record, cursor) {
    const base = record && record.sync_base && record.sync_base.recorded === true ? record.sync_base : null;
    const protectedCursor = cursor && (cursor.tombstone || cursor.conflict || cursor.intent_kind || cursor.delete_state === 'blocked' || cursor.delete_state === 'unknown' || cursor.delete_state === 'deleted');

    if (protectedCursor) {
      return 'protected';
    }

    const hasServer = Boolean(cursor && cursor.server_draft_id && cursor.server_revision);

    if (hasServer && cursor.acked_hash && cursor.acked_hash === record.content_hash) {
      return 'synced';
    }

    if (!hasServer) {
      return 'create';
    }

    if (base && Number(base.revision || 0) === Number(cursor.server_revision) && String(base.draft_id || '') === String(cursor.server_draft_id || '') && (base.hash || null) === (cursor.acked_hash || null)) {
      return 'patch';
    }

    return 'unbased';
  }

  function positiveOrNull (value) {
    const number = Number(value);

    return Number.isInteger(number) && number > 0 ? number : null;
  }

  function ignoreCall (job, reason) {
    job.running = false;

    if (job.hold) {
      job.status = 'held';
      job.reason = 'publish';
    } else if (job.conflict) {
      job.status = 'conflict';
      job.reason = job.tombstone ? 'discard_blocked' : 'conflict';
    } else {
      job.status = 'local';
      job.reason = reason || 'protected';
    }

    emit();

    return { ignored: true };
  }

  async function call (job, spec, sentEpoch) {
    await acquire();

    try {
      if (!readyForNetwork(job, sentEpoch, spec.method)) {
        return ignoreCall(job, job.durabilityStop ? 'ledger' : 'protected');
      }

      if (typeof ledger.read === 'function') {
        let row = null;

        try {
          row = await ledger.read(job.accountId, job.clientUuid);
        } catch (_error) {
          job.durabilityStop = true;
          job.stopped = true;
          job.reason = 'ledger';
          return ignoreCall(job, 'ledger');
        }

        if (!readyForNetwork(job, sentEpoch, spec.method)) {
          return ignoreCall(job, 'protected');
        }

        if (row && (row.conflict === true || row.delete_state === 'blocked' || (spec.method !== 'delete' && row.tombstone === true))) {
          job.tombstone = job.tombstone || row.tombstone === true;
          job.conflict = job.conflict || row.conflict === true;
          return ignoreCall(job, 'protected');
        }

        if (spec.method === 'delete') {
          if (row && (row.intent_kind || Number(row.server_revision) !== Number(job.deleteRevision) || String(row.server_draft_id || '') !== String(job.deleteDraftId || ''))) {
            if (job.deleteState !== 'deleted') {
              job.deleteState = 'unknown';
            }

            return ignoreCall(job, 'delete_unknown');
          }
        } else if (row && job.intent && (row.operation_id !== job.intent.id || row.operation_owner !== job.intent.owner || Number(row.intent_base_revision || 0) !== Number(job.intent.baseRevision || 0) || Number(row.server_revision || 0) !== Number(job.intent.baseRevision || 0))) {
          job.intentHeld = true;
          return ignoreCall(job, 'intent_held');
        }
      }

      if (!request) {
        return { status: 0, body: null };
      }

      return await request({
        accountId: job.accountId,
        method: spec.method,
        path: spec.path,
        body: spec.body,
      });
    } catch (_error) {
      return { status: 0, timedOut: true, body: null };
    } finally {
      release();
    }
  }

  function readyForNetwork (job, sentEpoch, method) {
    if (!current(job, sentEpoch) || protection !== 'ready' || unavailable || job.durabilityStop || job.stopped || job.conflict || job.hold) {
      return false;
    }

    if (method !== 'delete' && (job.tombstone || job.intentHeld)) {
      return false;
    }

    if (method === 'delete' && !deleteAllowed(job, sentEpoch)) {
      return false;
    }

    return true;
  }

  function current (job, sentEpoch) {
    return sentEpoch === epoch && bound === job.accountId && jobs.get(job.clientUuid) === job;
  }

  function currentEditMatches (job, sent) {
    if (job.pendingDirty && job.pendingHash !== sent.hash) {
      return false;
    }

    return job.contentHash === sent.hash && job.syncGeneration === sent.generation;
  }

  function markSynced (job, resource, sent) {
    job.serverDraftId = resource.draftId;
    job.ackedRevision = resource.revision;
    job.ackedHash = sent.hash;
    job.ackedGeneration = sent.generation;
    job.attempts = 0;
    job.waitingOnline = false;

    if (job.tombstone || job.hold || job.conflict) {
      return;
    }

    if (currentEditMatches(job, sent)) {
      job.status = 'synced';
      job.reason = null;
      job.pendingDirty = false;
      job.pendingHash = null;
      return;
    }

    job.status = 'local';
    job.reason = 'coalesced';
  }

  function markConflict (job, resource) {
    job.conflict = true;

    if (resource && resource.draftId) {
      job.serverDraftId = resource.draftId;
    }

    if (resource && resource.revision) {
      job.conflictRevision = resource.revision;
    }

    clearTimer(job);
    job.status = 'conflict';
    job.reason = 'conflict';
    job.attempts = 0;
    job.waitingOnline = false;
    emit();
  }

  function markFailed (job, reason) {
    job.status = 'failed';
    job.reason = reason;
    job.waitingOnline = false;
    emit();
  }

  function scheduleRetry (job, sentEpoch) {
    if (!current(job, sentEpoch) || job.hold || job.conflict) {
      return;
    }

    job.attempts += 1;
    const exhausted = job.attempts >= maxAttempts;
    const delay = Math.min(retryCapMs, retryBaseMs * (2 ** Math.max(job.attempts - 1, 0)));

    if (job.tombstone) {
      if (exhausted) {
        job.deleteState = 'unknown';
        job.status = 'local';
        job.reason = 'delete_unknown';
        emit();
        return;
      }

      job.deleteState = job.ackedRevision ? 'pending' : 'unknown';
      job.status = 'local';
      job.reason = 'retry';
      job.running = false;
      scheduleDelete(job, delay);
      emit();
      return;
    }

    if (exhausted) {
      markFailed(job, 'retry_exhausted');
      return;
    }

    job.status = 'local';
    job.reason = 'retry';
    job.running = false;
    scheduleJob(job, delay);
    emit();
  }

  function sameAck (job, resource) {
    return Boolean(resource)
      && resource.hash
      && resource.hash === job.ackedHash
      && Number(resource.revision) === Number(job.ackedRevision);
  }

  async function reconcile (job, resource, sent) {
    if (job.conflict) {
      await persist(job, { transition: 'conflict', conflictRevision: job.conflictRevision });
      return;
    }

    if (resource && sent && sameAck(job, resource) && resource.hash === sent.hash) {
      if (job.tombstone || job.hold) {
        job.serverDraftId = resource.draftId;
        job.ackedRevision = resource.revision;
        job.ackedHash = sent.hash;
        job.ackedGeneration = sent.generation;
        return;
      }

      const stored = await persist(job, {
        transition: 'finish',
        serverRevision: resource.revision,
        serverDraftId: resource.draftId,
        ackedHash: sent.hash,
        ackedGeneration: sent.generation,
      });

      if (stored === 'accepted') {
        markSynced(job, resource, sent);
        job.ackDirect = true;
      }

      if (!stored || job.blockedByLedger || job.conflict || job.tombstone || job.intent) {
        if (job.status === 'synced') {
          job.status = 'local';
          job.reason = job.durabilityStop ? 'ledger' : 'protected';
        }
      }

      emit();

      if (stored && job.reason === 'coalesced' && !job.pendingDirty && job.contentHash !== sent.hash && networkAllowed(job)) {
        scheduleJob(job, 0);
      }

      return;
    }

    if (sameAck(job, resource) && job.contentHash !== resource.hash && !job.tombstone && !job.hold && !job.pendingDirty) {
      job.status = 'local';
      job.reason = 'retry';
      scheduleRetry(job, epoch);
      return;
    }

    markConflict(job, resource);
    const stored = await persist(job, { transition: 'conflict', conflictRevision: job.conflictRevision });

    if (stored === 'stopped') {
      job.stopped = true;
      job.reason = 'ledger';
      emit();
    }
  }

  async function removeServer (job, sentEpoch) {
    if (job.conflict || job.deleteState === 'blocked') {
      job.deleteState = 'blocked';
      job.status = 'conflict';
      job.reason = 'discard_blocked';
      await persist(job, { transition: 'discard', conflict: true, deleteRevision: job.deleteRevision, deleteDraftId: job.deleteDraftId });
      return;
    }

    if (!job.deleteDraftId || !job.deleteRevision || Number(job.ackedRevision) !== Number(job.deleteRevision)) {
      job.deleteState = 'unknown';
      job.status = 'local';
      job.reason = 'delete_unknown';
      emit();
      return;
    }

    const response = await call(job, {
      method: 'delete',
      path: `/api/v1/fedibird/post_drafts/${job.deleteDraftId}`,
      body: { expected_revision: job.deleteRevision },
    }, sentEpoch);

    if (!current(job, sentEpoch)) {
      return;
    }

    if (!response || response.ignored) {
      job.deleteState = 'unknown';
      job.reason = 'delete_unknown';
      await persist(job, { transition: 'discard', deleteState: 'unknown', deleteRevision: job.deleteRevision, deleteDraftId: job.deleteDraftId });
      return;
    }

    if (response.status === 200 || response.status === 404) {
      job.attempts = 0;
      const stored = await persist(job, {
        transition: 'deleted',
        deleteRevision: job.deleteRevision,
        deleteDraftId: job.deleteDraftId,
      });

      if (!stored) {
        job.deleteState = 'unknown';
        job.status = 'local';
        job.reason = 'ledger';
      }

      emit();
      return;
    }

    if (response.status === 409) {
      const hinted = draftResource(response.body);

      job.conflict = true;
      job.conflictRevision = hinted ? hinted.revision : job.conflictRevision;
      job.deleteState = 'blocked';
      job.status = 'conflict';
      job.reason = 'discard_blocked';
      await persist(job, { transition: 'conflict', conflict: true, conflictRevision: job.conflictRevision });
      return;
    }

    const kind = failureKind(response);

    if (kind === 'retry') {
      scheduleRetry(job, sentEpoch);
      return;
    }

    job.deleteState = 'unknown';
    job.status = 'local';
    job.reason = 'delete_unknown';
    await persist(job, { transition: 'discard', deleteRevision: job.deleteRevision, deleteDraftId: job.deleteDraftId });
  }

  async function continueDiscard (job, sentEpoch) {
    if (!current(job, sentEpoch) || !job.tombstone || job.deleteState === 'deleted') {
      return;
    }

    if (protection !== 'ready' || unavailable || job.durabilityStop || job.stopped) {
      job.pendingDiscard = true;
      job.deleteState = 'unknown';
      job.status = 'local';
      job.reason = job.durabilityStop ? 'ledger' : 'boot';
      emit();
      return;
    }

    const stored = await persist(job, {
      transition: 'discard',
      deleteRevision: job.deleteRevision,
      deleteDraftId: job.deleteDraftId,
    });

    if (stored !== 'accepted' || job.durabilityStop) {
      if (job.deleteState !== 'deleted') {
        job.pendingDiscard = stored === 'stopped';
        job.deleteState = 'unknown';
        job.status = 'local';
        job.reason = job.durabilityStop ? 'ledger' : 'delete_unknown';
      }

      emit();
      return;
    }

    if (job.deleteState === 'deleted') {
      job.status = 'deleted';
      job.reason = null;
      emit();
      return;
    }

    if (job.conflict || job.deleteState === 'blocked') {
      job.deleteState = 'blocked';
      job.status = 'conflict';
      job.reason = 'discard_blocked';
      emit();
      return;
    }

    if ((job.intent && job.intent.unresolved) || job.deleteState === 'unknown' || job.deleteState === 'blocked' || !job.deleteRevision || !job.deleteDraftId || Number(job.ackedRevision) !== Number(job.deleteRevision)) {
      job.deleteState = job.conflict ? 'blocked' : 'unknown';
      job.status = job.deleteState === 'blocked' ? 'conflict' : 'local';
      job.reason = job.deleteState === 'blocked' ? 'discard_blocked' : 'delete_unknown';
      emit();
      return;
    }

    await removeServer(job, sentEpoch);
  }

  async function settleHeld (job, response, sent) {
    const learned = draftResource(response && response.body);
    const success = (response.status === 200 || response.status === 201) && learned && learned.hash === sent.hash;
    const kind = failureKind(response);
    let transition = 'unknown';
    let extra = { transition };

    if (success) {
      transition = 'finish';
      extra = {
        transition,
        serverRevision: learned.revision,
        serverDraftId: learned.draftId,
        ackedHash: sent.hash,
        ackedGeneration: sent.generation,
      };
    } else if (response.status === 409) {
      transition = 'conflict';
      extra = { transition, conflict: true, conflictRevision: learned && learned.revision };
    } else if (kind === 'scope' || kind === 'limit' || kind === 'too_large' || kind === 'invalid' || kind === 'missing') {
      transition = 'reject';
      extra = { transition };
    }

    await persist(job, extra);
    job.hold = true;
    job.status = 'held';
    job.reason = 'publish';
    emit();
  }

  async function push (job) {
    const sentEpoch = epoch;

    if (!current(job, sentEpoch) || protection !== 'ready' || job.stopped || job.durabilityStop || job.conflict) {
      return;
    }

    if (job.hold) {
      job.status = 'held';
      job.reason = 'publish';
      emit();
      return;
    }

    if (job.tombstone) {
      await continueDiscard(job, sentEpoch);
      emit();
      return;
    }

    if (online() === false) {
      job.status = 'local';
      job.reason = 'offline';
      job.waitingOnline = true;
      emit();
      return;
    }

    const payload = serverDraftPayload(job.payload);
    const size = storedPayloadBytes(payload);

    if (size > payloadMaxBytes) {
      markFailed(job, 'too_large');
      return;
    }

    const sent = {
      hash: job.contentHash,
      generation: job.syncGeneration,
      payload,
    };

    job.running = true;
    job.sendingHash = sent.hash;
    job.sendingGeneration = sent.generation;
    job.status = 'syncing';
    job.reason = null;
    emit();

    const sameIntent = Boolean(job.intent && job.intent.unresolved && job.intent.owner === ownerId && job.intent.id && job.intent.hash === job.contentHash);

    if (job.intent && job.intent.unresolved && !sameIntent) {
      job.running = false;
      job.status = 'local';
      job.reason = 'intent_held';
      emit();
      return;
    }

    if (!sameIntent) {
      const creatingNow = !job.serverDraftId || !job.ackedRevision;

      operationSeq += 1;
      job.intent = {
        id: `${ownerId}-${operationSeq}`,
        owner: ownerId,
        kind: creatingNow ? 'create' : 'patch',
        hash: sent.hash,
        baseRevision: creatingNow ? null : job.ackedRevision,
        expectedRevision: creatingNow ? 1 : Number(job.ackedRevision) + 1,
        draftId: creatingNow ? null : job.serverDraftId,
        state: 'open',
        unresolved: true,
      };

      const intentStored = await persist(job, { transition: 'claim' });

      if (job.durabilityStop) {
        job.running = false;
        job.stopped = true;
        job.status = 'local';
        job.reason = 'ledger';
        emit();
        return;
      }

      if (job.durabilityStop || intentStored !== 'accepted' || job.intentHeld || job.blockedByLedger || job.conflict || job.tombstone || job.unbased) {
        job.running = false;
        job.status = job.conflict ? 'conflict' : 'local';
        job.reason = job.conflict ? 'conflict' : 'intent_held';
        emit();
        return;
      }
    }

    const intent = job.intent;
    const creating = !intent || intent.kind === 'create';
    const response = await call(job, creating ? {
      method: 'post',
      path: '/api/v1/fedibird/post_drafts',
      body: { client_uuid: job.clientUuid, payload },
    } : {
      method: 'patch',
      path: `/api/v1/fedibird/post_drafts/${intent.draftId}`,
      body: { expected_revision: intent.baseRevision, payload },
    }, sentEpoch);

    job.running = false;
    job.sendingHash = null;
    job.sendingGeneration = null;

    if (!current(job, sentEpoch)) {
      return;
    }

    if (!response || response.ignored) {
      if (job.hold && job.intent) {
        await persist(job, { transition: 'reject' });
      }

      job.running = false;
      job.status = job.hold ? 'held' : 'local';

      if (job.hold) {
        job.reason = 'publish';
      } else if (job.conflict) {
        job.reason = 'conflict';
      } else {
        job.reason = 'protected';
      }

      emit();
      return;
    }

    if (job.hold) {
      await settleHeld(job, response, sent);
      return;
    }

    if (job.tombstone) {
      const learned = draftResource(response.body);

      if ((response.status === 200 || response.status === 201) && learned && learned.hash === sent.hash) {
        const acked = await persist(job, {
          transition: 'finish',
          serverRevision: learned.revision,
          serverDraftId: learned.draftId,
          ackedHash: sent.hash,
          ackedGeneration: sent.generation,
        });

        if (acked === 'accepted') {
          job.ackDirect = true;
          job.deleteRevision = learned.revision;
          job.deleteDraftId = learned.draftId;
          job.deleteState = 'pending';
          await persist(job, {
            transition: 'discard',
            deleteRevision: learned.revision,
            deleteDraftId: learned.draftId,
          });
        }

        if (acked === 'accepted' && deleteAllowed(job, sentEpoch)) {
          await removeServer(job, sentEpoch);
        }

        emit();
        return;
      }

      if (job.intent) {
        job.intent.unresolved = true;
      }

      if (response.status === 409) {
        markConflict(job, learned);
        job.deleteState = 'blocked';
        job.reason = 'discard_blocked';
        await persist(job, { transition: 'conflict', conflict: true, conflictRevision: job.conflictRevision });
        return;
      }

      if (job.intent) {
        job.intent.unresolved = true;
        job.intent.state = 'unknown';
      }

      job.probeHash = sent.hash;
      job.deleteState = 'unknown';
      job.reason = 'delete_unknown';
      await persist(job, { transition: 'unknown' });
      emit();
      return;
    }

    if (response.status === 200 || response.status === 201) {
      const learned = draftResource(response.body);

      if (!learned || (learned.hash && learned.hash !== sent.hash)) {
        await reconcile(job, learned, sent, sentEpoch);
        return;
      }

      const stored = await persist(job, {
        transition: 'finish',
        serverRevision: learned.revision,
        serverDraftId: learned.draftId,
        ackedHash: sent.hash,
        ackedGeneration: sent.generation,
      });

      if (stored === 'accepted') {
        markSynced(job, learned, sent);
        job.ackDirect = true;
      }

      if (stored !== 'accepted' || job.blockedByLedger || job.conflict || job.tombstone || (job.intent && job.intent.unresolved)) {
        if (job.status === 'synced') {
          job.status = 'local';
          job.reason = job.durabilityStop ? 'ledger' : 'protected';
        }
      }

      emit();

      if (stored === 'accepted' && job.reason === 'coalesced' && !job.pendingDirty && job.contentHash !== sent.hash && networkAllowed(job)) {
        scheduleJob(job, 0);
      }

      return;
    }

    if (response.status === 409) {
      markConflict(job, draftResource(response.body));

      if (job.intent) {
        job.intent.unresolved = true;
      }

      const stored = await persist(job, { transition: 'conflict', conflictRevision: job.conflictRevision });

      if (stored === 'stopped') {
        job.stopped = true;
        job.reason = 'ledger';
      }

      emit();
      return;
    }

    if (response.status === 0 || response.timedOut || response.status >= 500) {
      if (job.intent) {
        job.intent.state = 'unknown';
        job.intent.unresolved = true;
      }

      await persist(job, { transition: 'unknown' });
      scheduleRetry(job, sentEpoch);
      emit();
      return;
    }

    const kind = failureKind(response);

    if (kind === 'retry') {
      if (job.intent) {
        job.intent.state = 'unknown';
      }

      await persist(job, { transition: 'unknown' });
      scheduleRetry(job, sentEpoch);
      return;
    }

    if (kind === 'scope' || kind === 'limit' || kind === 'too_large' || kind === 'invalid' || kind === 'missing') {
      await persist(job, { transition: 'reject' });
      markFailed(job, kind);
      return;
    }

    markFailed(job, kind);
    emit();
  }

  function noteDirty (input) {
    if (!input || !bound || String(input.accountId) !== String(bound)) {
      return false;
    }

    const job = ensureJob(input.clientUuid);

    job.editedDuringBoot = protection !== 'ready';

    if (job.tombstone || job.hold) {
      return false;
    }

    if (!acceptPageEdit(job, input)) {
      return false;
    }

    job.pendingHash = input.contentHash || null;
    job.pendingDirty = Boolean(job.pendingHash) && job.pendingHash !== job.contentHash;

    if (job.conflict) {
      job.status = 'conflict';
      job.reason = 'conflict';
      emit();
      return true;
    }

    if (job.pendingDirty && job.status === 'synced') {
      job.status = 'local';
      job.reason = 'dirty';
      emit();
    } else if (job.pendingDirty && job.sendingHash && job.sendingHash !== job.pendingHash) {
      job.status = 'local';
      job.reason = 'dirty';
      emit();
    }

    return true;
  }

  function observeLocal (input, options = {}) {
    if (!input || !bound || String(input.accountId) !== String(bound)) {
      return Promise.resolve(false);
    }

    if (input.payload && String(input.payload.account_id) !== String(bound)) {
      return Promise.resolve(false);
    }

    const job = ensureJob(input.clientUuid);

    job.editedDuringBoot = protection !== 'ready';

    if (job.tombstone || job.hold || job.conflict) {
      if (job.conflict) {
        acceptPageEdit(job, input);
        job.pendingHash = input.contentHash || null;
        job.pendingDirty = job.pendingHash !== job.contentHash;
        job.status = 'conflict';
        job.reason = 'conflict';
        emit();
      }

      return Promise.resolve(false);
    }

    if (!acceptPageEdit(job, input)) {
      return Promise.resolve(false);
    }

    const previousHash = job.contentHash;

    job.accountId = bound;
    job.localRevision = Number(input.localRevision) || 0;

    if (input.contentHash !== previousHash) {
      job.attempts = 0;
    }

    if (job.durabilityStop) {
      job.status = 'local';
      job.reason = 'ledger';
      emit();
      return Promise.resolve(false);
    }

    const incomingBase = input.payload && input.payload.sync_base;
    const foreignBase = incomingBase && (
      incomingBase.recorded === false
      || (incomingBase.recorded === true && job.syncBase && job.syncBase.recorded === true && !sameSyncBase(incomingBase, job.syncBase) && !sameSyncBase(incomingBase, job.previousBase))
    );

    if (foreignBase && job.ackedRevision && input.contentHash !== job.ackedHash) {
      job.contentHash = input.contentHash || job.contentHash;
      job.payload = input.payload;
      job.baseVerified = false;
      job.unbased = true;
      job.pendingSend = false;
      job.verifiedHash = null;
      job.status = 'local';
      job.reason = 'unbased';
      emit();
      return Promise.resolve(true);
    }

    if (job.intent && job.intent.unresolved && input.contentHash !== job.intent.hash) {
      job.accountId = bound;
      job.localRevision = Number(input.localRevision) || job.localRevision;
      job.pendingHash = input.contentHash || null;
      if (input.contentHash && input.contentHash !== job.contentHash) {
        bumpSyncGeneration(job, input.contentHash);
        job.contentHash = input.contentHash;
        job.payload = input.payload;
      }
      job.pendingDirty = false;
      job.status = 'local';
      job.reason = 'intent_held';
      emit();
      return Promise.resolve(true);
    }

    bumpSyncGeneration(job, input.contentHash || null);
    job.contentHash = input.contentHash || null;
    job.payload = input.payload;

    if (job.pendingHash === job.contentHash) {
      job.pendingDirty = false;
      job.pendingHash = null;
    }

    if (incomingBase && incomingBase.recorded === true && job.syncBase && job.syncBase.recorded === true && job.baseVerified && !sameSyncBase(incomingBase, job.syncBase) && !sameSyncBase(incomingBase, job.previousBase)) {
      job.baseVerified = false;
      job.unbased = true;
      job.pendingSend = false;
      job.verifiedHash = null;
      job.status = 'local';
      job.reason = 'unbased';
      emit();
      return Promise.resolve(true);
    }

    if (job.unbased) {
      job.status = 'local';
      job.reason = 'unbased';
      emit();
      return Promise.resolve(true);
    }

    if (job.conflict) {
      job.status = 'conflict';
      job.reason = 'conflict';
      emit();
      return Promise.resolve(true);
    }

    if (job.ackedHash && job.ackedHash === job.contentHash && job.serverDraftId && job.ackedRevision && !job.pendingDirty && !(job.intent && job.intent.unresolved)) {
      if (job.status !== 'synced') {
        job.status = 'local';
        job.reason = null;
        emit();
      }

      return Promise.resolve(true);
    }

    if (job.running) {
      job.status = job.sendingHash === job.contentHash && !job.pendingDirty ? 'syncing' : 'local';
      job.reason = job.status === 'local' ? 'coalesced' : null;
      emit();
      return Promise.resolve(true);
    }

    job.status = 'local';
    job.reason = null;

    if (previousHash !== job.contentHash || !job.ackedRevision) {
      scheduleJob(job, options.immediate ? 0 : serverDebounceMs);
    }

    emit();
    return Promise.resolve(true);
  }

  function tombstoneRow (accountId, clientUuid) {
    const job = jobs.get(String(clientUuid));
    const conflict = Boolean(job && job.conflict);
    let deleteState = 'unknown';

    if (conflict) {
      deleteState = 'blocked';
    } else if (job && job.ackedRevision) {
      deleteState = 'pending';
    }

    return {
      account_id: String(accountId),
      client_uuid: String(clientUuid),
      server_draft_id: job && !conflict ? job.serverDraftId : null,
      server_revision: job && !conflict ? job.ackedRevision : null,
      conflict,
      conflict_revision: job ? job.conflictRevision : null,
      acked_hash: job ? job.ackedHash : null,
      sync_generation: job ? job.syncGeneration : null,
      tombstone: true,
      delete_state: deleteState,
      delete_revision: job && !conflict && !unresolvedIntent(job) ? job.deleteRevision || job.ackedRevision : null,
      delete_draft_id: job && !conflict && !unresolvedIntent(job) ? job.deleteDraftId || job.serverDraftId : null,
      cursor_version: job ? job.cursorVersion || 0 : 0,
      operation_id: job && job.intent ? job.intent.id : null,
      operation_owner: job && job.intent ? job.intent.owner : null,
      probe_hash: job && (job.sendingHash || job.probeHash || job.contentHash) || null,
      intent_kind: job && job.intent ? job.intent.kind : null,
      intent_hash: job && job.intent ? job.intent.hash : null,
      intent_base_revision: job && job.intent ? job.intent.baseRevision : null,
      intent_expected_revision: job && job.intent ? job.intent.expectedRevision : null,
      intent_draft_id: job && job.intent ? job.intent.draftId : null,
    };
  }

  function unresolvedIntent (job) {
    return Boolean(job && job.intent && job.intent.unresolved);
  }

  function rememberTombstone (row) {
    if (!row) {
      return Promise.resolve(false);
    }

    const previous = bound;

    if (!bound) {
      bound = String(row.account_id);
    }

    const job = ensureJob(row.client_uuid);

    job.accountId = String(row.account_id);
    applyCursor(job, row);
    job.tombstone = true;
    job.conflict = row.conflict === true;
    job.deleteState = row.delete_state || (job.conflict ? 'blocked' : 'unknown');
    job.probeHash = row.probe_hash || job.probeHash;

    if (!previous) {
      bound = previous;
    }

    return ledger.commit(row.account_id, row.client_uuid, {
      ...row,
      account_id: String(row.account_id),
      client_uuid: String(row.client_uuid),
      tombstone: true,
      transition: 'discard',
      cursor_version: job.cursorVersion || 0,
      delete_revision: job.deleteRevision,
      delete_draft_id: job.deleteDraftId,
    }).then(() => true, () => false);
  }

  function noteDiscard (input) {
    if (!input || !input.clientUuid) {
      return Promise.resolve(false);
    }

    const accountId = input.accountId ? String(input.accountId) : bound;

    if (!accountId || (bound && accountId !== String(bound))) {
      return Promise.resolve(false);
    }

    const job = ensureJob(input.clientUuid);

    job.accountId = accountId;
    job.tombstone = true;
    job.hold = false;
    clearTimer(job);

    if (!job.probeHash) {
      job.probeHash = job.sendingHash || null;
    }

    const unresolved = Boolean(job.intent && job.intent.unresolved);

    if (job.conflict) {
      job.deleteState = 'blocked';
      job.status = 'conflict';
      job.reason = 'discard_blocked';
    } else if (unresolved || job.intent && job.intent.state === 'unknown') {
      job.deleteState = 'unknown';
      job.deleteRevision = null;
      job.status = 'local';
      job.reason = 'delete_unknown';
    } else if (job.ackDirect && job.ackedRevision && job.serverDraftId) {
      job.deleteRevision = job.ackedRevision;
      job.deleteDraftId = job.serverDraftId;
      job.deleteState = 'pending';
      job.status = 'local';
      job.reason = 'discard';
    } else {
      job.deleteRevision = null;
      job.deleteState = 'pending';
      job.status = 'local';
      job.reason = 'discard';
    }

    emit();

    return serial(job.clientUuid, async () => {
      if (protection !== 'ready' || unavailable) {
        job.pendingDiscard = true;
        job.deleteState = 'unknown';
        job.reason = 'boot';
        emit();
        return;
      }

      if (job.deleteState === 'deleted' || job.deleteState === 'blocked' || job.conflict) {
        job.deleteState = job.conflict ? 'blocked' : job.deleteState;
        await persist(job, { transition: 'discard', deleteRevision: job.deleteRevision, deleteDraftId: job.deleteDraftId });
        emit();
        return;
      }

      const storedDiscard = await persist(job, { transition: 'discard', deleteRevision: job.deleteRevision, deleteDraftId: job.deleteDraftId });

      if (storedDiscard !== 'accepted' || job.durabilityStop || !current(job, epoch) || job.running) {
        if (job.deleteState !== 'deleted') {
          job.deleteState = 'unknown';
          job.status = 'local';
          job.reason = job.durabilityStop ? 'ledger' : 'delete_unknown';
          emit();
        }

        return;
      }

      if (job.deleteState === 'deleted') {
        job.status = 'deleted';
        job.reason = null;
        emit();
        return;
      }

      await continueDiscard(job, epoch);
      emit();
    });
  }

  function notePublish (input) {
    if (!input || !input.clientUuid) {
      return;
    }

    const job = jobs.get(String(input.clientUuid));

    if (!job || (bound && String(input.accountId || bound) !== String(bound))) {
      return;
    }

    job.hold = true;
    clearTimer(job);

    if (!job.running) {
      job.status = 'held';
      job.reason = 'publish';
    }

    emit();
  }

  function bindAccount (accountId) {
    const next = accountId === null || accountId === undefined || accountId === '' ? null : String(accountId);

    if (next === bound) {
      return;
    }

    epoch += 1;
    protectionTicket += 1;
    bound = next;
    jobs.forEach((job) => clearTimer(job));
    jobs.clear();
    protection = next ? 'pending' : 'unavailable';
    readyPromise = new Promise((resolve) => {
      readyResolve = resolve;
    });
    emit();
  }

  function finishProtection (state) {
    protection = state;
    unavailable = state === 'unavailable';
    readyResolve();
    emit();
  }

  async function resume (listLocal) {
    if (!bound) {
      finishProtection('unavailable');
      return;
    }

    const sentEpoch = epoch;
    const ticket = protectionTicket;
    const accountId = bound;
    let cursors = [];

    try {
      cursors = await ledger.list(accountId);
    } catch (_error) {
      if (ticket === protectionTicket) {
        finishProtection('unavailable');
      }

      return;
    }

    if (sentEpoch !== epoch || bound !== accountId || ticket !== protectionTicket) {
      return;
    }

    const byUuid = new Map();

    cursors.forEach((cursor) => {
      if (!cursor || String(cursor.account_id) !== accountId) {
        return;
      }

      byUuid.set(String(cursor.client_uuid), cursor);

      const job = ensureJob(cursor.client_uuid);

      applyCursor(job, cursor);
      job.accountId = accountId;

      if (cursor.tombstone || cursor.conflict || cursor.delete_state === 'blocked' || cursor.delete_state === 'unknown' || cursor.delete_state === 'deleted') {
        if (cursor.conflict || cursor.delete_state === 'blocked') {
          job.conflict = true;
          job.tombstone = cursor.tombstone === true || job.tombstone;
          job.deleteState = 'blocked';
          job.status = 'conflict';
          job.reason = cursor.tombstone ? 'discard_blocked' : 'conflict';
        } else if (cursor.delete_state === 'deleted') {
          job.tombstone = true;
          job.deleteState = 'deleted';
          job.status = 'deleted';
          job.reason = null;
        } else if (cursor.delete_state === 'unknown') {
          job.tombstone = true;
          job.deleteState = 'unknown';
          job.status = 'local';
          job.reason = 'delete_unknown';
        } else if (cursor.tombstone && cursor.server_revision) {
          job.tombstone = true;
          job.deleteState = 'pending';
          job.status = 'local';
          job.reason = 'discard';
        } else if (cursor.tombstone) {
          job.tombstone = true;
          job.deleteState = 'unknown';
          job.status = 'local';
          job.reason = 'delete_unknown';
        }
      }
    });

    let records = [];

    try {
      records = typeof listLocal === 'function' ? await listLocal() : [];
    } catch (_error) {
      if (ticket === protectionTicket) {
        finishProtection('unavailable');
      }

      return;
    }

    if (sentEpoch !== epoch || bound !== accountId || ticket !== protectionTicket) {
      return;
    }

    const listed = new Map();

    (records || []).forEach((record) => {
      if (record && String(record.account_id) === accountId) {
        listed.set(String(record.client_draft_uuid), record);
      }
    });

    const ids = new Set(listed.keys());

    jobs.forEach((job, id) => {
      if (job.editedDuringBoot) {
        ids.add(id);
      }
    });

    const stillHere = () => sentEpoch === epoch && bound === accountId && ticket === protectionTicket;

    const settleResume = (job, listedRecord, cursor) => {
      const source = job.editedDuringBoot && job.payload ? job.payload : listedRecord;

      if (!source) {
        job.pendingSend = false;
        return;
      }

      if (!job.editedDuringBoot) {
        job.contentHash = source.content_hash;
        job.payload = source;
        job.localRevision = Number(source.revision) || 0;
      }

      const mode = resumeMode(source, cursor);
      const newerDirty = job.pendingDirty && job.pendingHash && job.pendingHash !== source.content_hash;

      job.verifiedHash = source.content_hash || null;
      job.syncBase = source.sync_base && source.sync_base.recorded === true ? source.sync_base : null;

      if (mode === 'protected') {
        if (cursor) {
          applyCursor(job, cursor);
        }

        job.baseVerified = false;
        job.pendingSend = false;

        if (cursor && cursor.intent_kind && !cursor.tombstone && !cursor.conflict) {
          job.status = 'local';
          job.reason = 'intent_held';
        }

        return;
      }

      if (mode === 'synced' && job.contentHash === source.content_hash && !newerDirty) {
        applyCursor(job, cursor);
        job.baseVerified = true;
        job.unbased = false;
        job.pendingSend = false;
        job.status = 'synced';
        job.reason = null;
        return;
      }

      if (mode === 'synced' && newerDirty) {
        applyCursor(job, cursor);
        job.baseVerified = false;
        job.pendingSend = false;
        job.status = 'local';
        job.reason = 'dirty';
        return;
      }

      if (mode === 'create' && !cursor) {
        job.baseVerified = true;
        job.unbased = false;
        job.ackedRevision = null;
        job.serverDraftId = null;
        job.ackedHash = null;
        job.ackDirect = false;
        job.pendingSend = true;
        return;
      }

      if (mode === 'patch' && job.contentHash === source.content_hash && !newerDirty) {
        applyCursor(job, cursor);
        job.baseVerified = true;
        job.unbased = false;
        job.pendingSend = job.contentHash !== job.ackedHash;
        return;
      }

      if ((job.intent && job.intent.unresolved) || job.baseVerified) {
        return;
      }

      job.baseVerified = false;
      job.unbased = true;
      job.ackedRevision = null;
      job.serverDraftId = null;
      job.ackedHash = null;
      job.ackDirect = false;
      job.pendingSend = false;
      job.verifiedHash = null;
      job.status = 'local';
      job.reason = 'unbased';
    };

    for (const id of ids) {
      if (!stillHere()) {
        return;
      }

      let cursor = byUuid.get(id) || null;

      if (typeof ledger.read === 'function') {
        try {
          cursor = await ledger.read(accountId, id);
        } catch (_error) {
          if (ticket === protectionTicket) {
            finishProtection('unavailable');
          }

          return;
        }
      }

      if (!stillHere()) {
        return;
      }

      settleResume(ensureJob(id), listed.get(id) || null, cursor);
    }

    const late = [];

    jobs.forEach((job, id) => {
      if (job.editedDuringBoot && (!ids.has(id) || (job.verifiedHash && job.contentHash !== job.verifiedHash))) {
        late.push(id);
      }
    });

    for (const id of late) {
      if (!stillHere()) {
        return;
      }

      let cursor = null;

      if (typeof ledger.read === 'function') {
        try {
          cursor = await ledger.read(accountId, id);
        } catch (_error) {
          if (ticket === protectionTicket) {
            finishProtection('unavailable');
          }

          return;
        }
      }

      if (!stillHere()) {
        return;
      }

      settleResume(jobs.get(id), null, cursor);
    }

    if (!stillHere()) {
      return;
    }

    finishProtection('ready');
    jobs.forEach((job) => {
      if (job.pendingDiscard) {
        job.pendingDiscard = false;
        serial(job.clientUuid, () => continueDiscard(job, epoch));
        return;
      }

      if (job.tombstone && job.deleteState === 'pending' && job.ackDirect && job.ackedRevision && !job.conflict) {
        serial(job.clientUuid, () => continueDiscard(job, epoch));
        return;
      }

      if (job.conflict || job.tombstone || job.stopped || job.unbased || !job.baseVerified) {
        return;
      }

      if (job.pendingSend && job.baseVerified && job.contentHash === job.verifiedHash && job.contentHash !== job.ackedHash) {
        scheduleJob(job, 0);
      }
    });
    emit();
  }

  function snapshot () {
    const drafts = {};

    jobs.forEach((job, clientUuid) => {
      drafts[clientUuid] = {
        status: job.status,
        reason: job.reason,
        clientUuid: job.clientUuid,
        editGeneration: job.editGeneration,
        localRevision: job.localRevision,
        serverDraftId: job.serverDraftId,
        serverRevision: job.ackedRevision,
        conflictRevision: job.conflictRevision,
        conflict: job.conflict === true,
        deleteState: job.deleteState,
        syncGeneration: job.syncGeneration,
        ackedGeneration: job.ackedGeneration,
        contentHash: job.contentHash,
        ackedHash: job.ackedHash,
        tombstone: job.tombstone === true,
        held: job.hold === true,
        intentUnresolved: Boolean(job.intent && job.intent.unresolved),
      };
    });

    return {
      accountId: bound,
      unavailable,
      protection,
      drafts,
    };
  }

  function settle () {
    const pending = [];

    chains.forEach((chain) => pending.push(chain));

    return Promise.all(pending).then(() => undefined);
  }

  return {
    bindAccount,
    observeLocal,
    noteDirty,
    noteDiscard,
    notePublish,
    tombstoneRow,
    rememberTombstone,
    resume,
    localBase (clientUuid) {
      const job = clientUuid ? jobs.get(String(clientUuid)) : null;

      if (job && job.baseVerified && !job.unbased) {
        return {
          recorded: true,
          revision: job.ackedRevision || null,
          draft_id: job.serverDraftId || null,
          hash: job.ackedHash || null,
        };
      }

      if (job && job.syncBase && job.syncBase.recorded === true) {
        return job.syncBase;
      }

      if (!job && protection === 'ready') {
        return {
          recorded: true,
          revision: null,
          draft_id: null,
          hash: null,
        };
      }

      return null;
    },
    snapshot,
    settle,
    whenReady () {
      return readyPromise;
    },
    subscribe (listener) {
      listeners.add(listener);

      return () => listeners.delete(listener);
    },
    dispose () {
      unsubscribeOnline();
      jobs.forEach((job) => clearTimer(job));
    },
  };
}
