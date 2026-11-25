// Server sync for a local composer draft. IndexedDB stays the copy that
// survives a reload. A server acknowledgement counts only when its payload
// hash is the hash of the edit that is current now.
//
// Publishing a post must not delete the server draft. #804 decides how a
// server draft is consumed. An explicit discard does delete it, and a save
// that finishes after that discard deletes the row it just created instead
// of leaving the draft behind.
//
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

export function createMemorySyncLedger () {
  const rows = new Map();
  const keyFor = (accountId, clientUuid) => `${String(accountId)}\u0000${String(clientUuid)}`;

  return {
    read (accountId, clientUuid) {
      return Promise.resolve(rows.get(keyFor(accountId, clientUuid)) || null);
    },

    write (record) {
      const stored = { ...record, account_id: String(record.account_id), client_uuid: String(record.client_uuid) };

      rows.set(keyFor(stored.account_id, stored.client_uuid), stored);

      return Promise.resolve(stored);
    },

    list (accountId) {
      const matched = [];

      rows.forEach((record) => {
        if (String(record.account_id) === String(accountId)) {
          matched.push({ ...record });
        }
      });

      return Promise.resolve(matched);
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
} = {}) {
  const jobs = new Map();
  const chains = new Map();
  const listeners = new Set();
  let bound = null;
  let epoch = 0;
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

  function scheduleJob (job, delay) {
    if (!job || job.tombstone || job.hold || job.running || job.conflict) {
      return;
    }

    clearTimer(job);
    job.timer = schedule(() => {
      job.timer = null;
      serial(job.clientUuid, () => push(job));
    }, delay);
  }

  function scheduleDelete (job, delay) {
    if (!job || !job.tombstone || job.conflict || job.deleteState === 'deleted' || job.deleteState === 'blocked') {
      return;
    }

    clearTimer(job);
    job.timer = schedule(() => {
      job.timer = null;
      serial(job.clientUuid, () => continueDiscard(job, epoch));
    }, delay);
  }

  function cursorFrom (job, extra = {}) {
    return {
      account_id: job.accountId,
      client_uuid: job.clientUuid,
      server_draft_id: extra.serverDraftId === undefined ? job.serverDraftId : extra.serverDraftId,
      server_revision: extra.serverRevision === undefined ? job.ackedRevision : extra.serverRevision,
      acked_hash: extra.ackedHash === undefined ? job.ackedHash : extra.ackedHash,
      acked_generation: extra.ackedGeneration === undefined ? job.ackedGeneration : extra.ackedGeneration,
      sync_generation: extra.syncGeneration === undefined ? job.syncGeneration : extra.syncGeneration,
      conflict: extra.conflict === undefined ? job.conflict === true : extra.conflict === true,
      conflict_revision: extra.conflictRevision === undefined ? job.conflictRevision : extra.conflictRevision,
      delete_state: extra.deleteState === undefined ? job.deleteState : extra.deleteState,
      probe_hash: extra.probeHash === undefined ? job.probeHash : extra.probeHash,
      tombstone: extra.tombstone === undefined ? job.tombstone === true : extra.tombstone === true,
    };
  }

  function persist (job, extra) {
    if (!job.accountId) {
      return Promise.resolve(false);
    }

    return ledger.write(cursorFrom(job, extra)).then(() => true, () => {
      if (job.tombstone && job.deleteState === 'deleted') {
        job.deleteState = 'unknown';
        job.status = 'local';
        job.reason = 'ledger';
      }

      return false;
    });
  }

  function applyCursor (job, cursor) {
    if (!cursor || String(cursor.account_id) !== String(job.accountId)) {
      return;
    }

    job.serverDraftId = cursor.server_draft_id || null;
    job.ackedRevision = Number(cursor.server_revision) || null;
    job.ackedHash = cursor.acked_hash || null;
    job.ackedGeneration = Number(cursor.acked_generation) || null;
    job.syncGeneration = Number(cursor.sync_generation) || job.syncGeneration || 0;
    job.editGeneration = job.syncGeneration;
    job.conflict = cursor.conflict === true;
    job.conflictRevision = Number(cursor.conflict_revision) || null;
    job.deleteState = cursor.delete_state || null;
    job.probeHash = cursor.probe_hash || null;
    job.tombstone = cursor.tombstone === true;
  }

  async function call (job, spec, sentEpoch) {
    await acquire();

    try {
      if (sentEpoch !== epoch || bound !== job.accountId) {
        return { ignored: true };
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
      emit();
      return;
    }

    job.status = 'local';
    job.reason = 'coalesced';

    if (!job.pendingDirty && job.contentHash !== sent.hash) {
      scheduleJob(job, 0);
    }
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
        return;
      }

      job.deleteState = job.ackedRevision ? 'pending' : 'unknown';
      job.status = 'local';
      job.reason = 'retry';
      job.running = false;
      scheduleDelete(job, delay);
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
  }

  async function readServer (job, draftId, sentEpoch) {
    const response = await call(job, {
      method: 'get',
      path: `/api/v1/fedibird/post_drafts/${draftId}`,
    }, sentEpoch);

    if (!response || response.ignored) {
      return { ignored: true };
    }

    if (response.status === 200) {
      return { resource: draftResource(response.body) };
    }

    if (response.status === 404) {
      return { missing: true };
    }

    return { failed: true, response };
  }

  function sameAck (job, resource) {
    return Boolean(resource)
      && resource.hash
      && resource.hash === job.ackedHash
      && Number(resource.revision) === Number(job.ackedRevision);
  }

  async function reconcile (job, resource, sent) {
    if (job.conflict) {
      await persist(job);
      return;
    }

    if (resource && resource.hash && sent && resource.hash === sent.hash) {
      if (job.tombstone || job.hold) {
        job.serverDraftId = resource.draftId;
        job.ackedRevision = resource.revision;
        job.ackedHash = sent.hash;
        job.ackedGeneration = sent.generation;
        await persist(job);
        return;
      }

      markSynced(job, resource, sent);
      await persist(job);
      return;
    }

    if (sameAck(job, resource) && job.contentHash !== resource.hash && !job.tombstone && !job.hold && !job.pendingDirty) {
      job.attempts = 0;
      job.status = 'local';
      job.reason = 'coalesced';
      await persist(job);
      scheduleJob(job, 0);
      return;
    }

    markConflict(job, resource);
    await persist(job);
  }

  async function removeServer (job, sentEpoch) {
    if (job.conflict || job.deleteState === 'blocked') {
      job.deleteState = 'blocked';
      job.status = 'conflict';
      job.reason = 'discard_blocked';
      await persist(job, { tombstone: true, deleteState: 'blocked' });
      return;
    }

    if (!job.serverDraftId || !job.ackedRevision) {
      job.deleteState = 'unknown';
      job.status = 'local';
      job.reason = 'delete_unknown';
      await persist(job, { tombstone: true, deleteState: 'unknown' });
      return;
    }

    const response = await call(job, {
      method: 'delete',
      path: `/api/v1/fedibird/post_drafts/${job.serverDraftId}`,
      body: { expected_revision: job.ackedRevision },
    }, sentEpoch);

    if (!response || response.ignored) {
      job.deleteState = 'unknown';
      job.reason = 'delete_unknown';
      await persist(job, { tombstone: true, deleteState: 'unknown' });
      return;
    }

    if (!current(job, sentEpoch)) {
      if (response.status === 200 || response.status === 404) {
        await ledger.write(cursorFrom(job, {
          tombstone: true,
          serverDraftId: null,
          serverRevision: null,
          deleteState: 'deleted',
        }));
      }

      return;
    }

    if (response.status === 200 || response.status === 404) {
      job.serverDraftId = null;
      job.ackedRevision = null;
      job.deleteState = 'deleted';
      job.status = 'deleted';
      job.reason = null;
      job.attempts = 0;
      const stored = await persist(job, {
        tombstone: true,
        serverDraftId: null,
        serverRevision: null,
        deleteState: 'deleted',
      });

      if (!stored) {
        job.deleteState = 'unknown';
        job.status = 'local';
        job.reason = 'ledger';
      }

      return;
    }

    if (response.status === 409) {
      const hinted = draftResource(response.body);

      job.conflict = true;
      job.conflictRevision = hinted ? hinted.revision : job.conflictRevision;
      job.deleteState = 'blocked';
      job.status = 'conflict';
      job.reason = 'discard_blocked';
      await persist(job, { tombstone: true, deleteState: 'blocked', conflict: true });
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
    await persist(job, { tombstone: true, deleteState: 'unknown' });
  }

  async function probeDiscard (job, sentEpoch) {
    if (!current(job, sentEpoch) || job.conflict || job.deleteState === 'blocked') {
      return;
    }

    let maxId = null;

    for (let page = 0; page < 4; page += 1) {
      const path = maxId
        ? `/api/v1/fedibird/post_drafts?limit=40&max_id=${maxId}`
        : '/api/v1/fedibird/post_drafts?limit=40';
      const response = await call(job, { method: 'get', path }, sentEpoch);

      if (!response || response.ignored || response.status !== 200 || !Array.isArray(response.body)) {
        scheduleRetry(job, sentEpoch);
        return;
      }

      const found = response.body.find(row => row && String(row.client_uuid) === String(job.clientUuid));

      if (found && found.draft_id) {
        const full = await readServer(job, found.draft_id, sentEpoch);

        if (full && full.ignored) {
          return;
        }

        if (full && full.resource && job.probeHash && full.resource.hash === job.probeHash) {
          job.serverDraftId = full.resource.draftId;
          job.ackedRevision = full.resource.revision;
          job.ackedHash = full.resource.hash;
          await removeServer(job, sentEpoch);
          return;
        }

        job.conflict = true;
        job.conflictRevision = full && full.resource ? full.resource.revision : (Number(found.revision) || null);
        job.serverDraftId = String(found.draft_id);
        job.deleteState = 'blocked';
        job.status = 'conflict';
        job.reason = 'discard_blocked';
        await persist(job, { tombstone: true, deleteState: 'blocked', conflict: true });
        return;
      }

      if (response.body.length < 40) {
        break;
      }

      const last = response.body[response.body.length - 1];

      maxId = last && last.draft_id;
      if (!maxId) {
        break;
      }
    }

    job.serverDraftId = null;
    job.ackedRevision = null;
    job.deleteState = 'deleted';
    job.status = 'deleted';
    job.reason = null;
    job.attempts = 0;
    const stored = await persist(job, {
      tombstone: true,
      serverDraftId: null,
      serverRevision: null,
      deleteState: 'deleted',
    });

    if (!stored) {
      job.deleteState = 'unknown';
      job.status = 'local';
      job.reason = 'ledger';
    }
  }

  async function continueDiscard (job, sentEpoch) {
    if (!current(job, sentEpoch) || !job.tombstone || job.deleteState === 'deleted') {
      return;
    }

    if (job.conflict || job.deleteState === 'blocked') {
      job.deleteState = 'blocked';
      job.status = 'conflict';
      job.reason = 'discard_blocked';
      await persist(job, { tombstone: true, deleteState: 'blocked' });
      return;
    }

    if (!job.serverDraftId || !job.ackedRevision) {
      if (!job.probeHash) {
        job.deleteState = 'deleted';
        job.status = 'deleted';
        job.reason = null;
        await persist(job, { tombstone: true, deleteState: 'deleted' });
        return;
      }

      await probeDiscard(job, sentEpoch);
      return;
    }

    await removeServer(job, sentEpoch);
  }

  async function push (job) {
    const sentEpoch = epoch;

    if (!current(job, sentEpoch)) {
      return;
    }

    if (job.hold) {
      job.status = 'held';
      job.reason = 'publish';
      return;
    }

    if (job.tombstone) {
      await continueDiscard(job, sentEpoch);
      return;
    }

    if (online() === false) {
      job.status = 'local';
      job.reason = 'offline';
      job.waitingOnline = true;
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

    const creating = !job.serverDraftId || !job.ackedRevision;
    const response = await call(job, creating ? {
      method: 'post',
      path: '/api/v1/fedibird/post_drafts',
      body: { client_uuid: job.clientUuid, payload },
    } : {
      method: 'patch',
      path: `/api/v1/fedibird/post_drafts/${job.serverDraftId}`,
      body: { expected_revision: job.ackedRevision, payload },
    }, sentEpoch);

    job.running = false;
    job.sendingHash = null;
    job.sendingGeneration = null;

    if (!response || response.ignored || !current(job, sentEpoch)) {
      if (response && !response.ignored && response.status && sent.hash) {
        const learned = draftResource(response.body);

        if ((response.status === 200 || response.status === 201) && learned && learned.hash === sent.hash) {
          await ledger.write({
            account_id: job.accountId,
            client_uuid: job.clientUuid,
            server_draft_id: learned.draftId,
            server_revision: learned.revision,
            acked_hash: sent.hash,
            acked_generation: sent.generation,
            sync_generation: sent.generation,
            conflict: false,
            tombstone: false,
            delete_state: null,
          });
        }
      }

      return;
    }

    if (job.hold) {
      const learned = draftResource(response.body);

      if ((response.status === 200 || response.status === 201) && learned && learned.hash === sent.hash) {
        job.serverDraftId = learned.draftId;
        job.ackedRevision = learned.revision;
        job.ackedHash = sent.hash;
        job.ackedGeneration = sent.generation;
      }

      job.status = 'held';
      job.reason = 'publish';
      await persist(job);
      return;
    }

    if (job.tombstone) {
      const learned = draftResource(response.body);

      if ((response.status === 200 || response.status === 201) && learned && learned.hash === sent.hash) {
        job.serverDraftId = learned.draftId;
        job.ackedRevision = learned.revision;
        job.ackedHash = sent.hash;
        await removeServer(job, sentEpoch);
        return;
      }

      if (response.status === 409) {
        markConflict(job, learned);
        job.deleteState = 'blocked';
        job.reason = 'discard_blocked';
        await persist(job, { tombstone: true, deleteState: 'blocked', conflict: true });
        return;
      }

      job.probeHash = sent.hash;
      job.deleteState = 'unknown';
      job.reason = 'delete_unknown';
      await persist(job, { tombstone: true, deleteState: 'unknown', probeHash: sent.hash });
      await probeDiscard(job, sentEpoch);
      return;
    }

    if (response.status === 200 || response.status === 201) {
      const learned = draftResource(response.body);

      if (!learned || (learned.hash && learned.hash !== sent.hash)) {
        await reconcile(job, learned, sent, sentEpoch);
        return;
      }

      markSynced(job, learned, sent);
      await persist(job);
      return;
    }

    if (response.status === 409) {
      const hinted = draftResource(response.body);
      const fetched = hinted ? await readServer(job, hinted.draftId, sentEpoch) : { failed: true };

      if (fetched && fetched.ignored) {
        return;
      }

      if (fetched && fetched.resource) {
        await reconcile(job, fetched.resource, sent, sentEpoch);
        return;
      }

      if (fetched && fetched.missing) {
        job.serverDraftId = null;
        job.ackedRevision = null;
        scheduleRetry(job, sentEpoch);
        return;
      }

      scheduleRetry(job, sentEpoch);
      return;
    }

    if (!creating && (response.status === 0 || response.timedOut || response.status >= 500)) {
      const fetched = await readServer(job, job.serverDraftId, sentEpoch);

      if (fetched && fetched.ignored) {
        return;
      }

      if (fetched && fetched.resource) {
        await reconcile(job, fetched.resource, sent, sentEpoch);
        return;
      }
    }

    const kind = failureKind(response);

    if (kind === 'retry') {
      scheduleRetry(job, sentEpoch);
      return;
    }

    if (kind === 'missing' && !creating) {
      job.serverDraftId = null;
      job.ackedRevision = null;
      markFailed(job, 'missing');
      await persist(job, { serverDraftId: null, serverRevision: null });
      return;
    }

    markFailed(job, kind);
    await persist(job);
    emit();
  }

  function noteDirty (input) {
    if (!input || !bound || String(input.accountId) !== String(bound)) {
      return false;
    }

    const job = ensureJob(input.clientUuid);

    job.observed = true;

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

    job.observed = true;

    if (job.tombstone || job.hold) {
      return Promise.resolve(false);
    }

    if (!acceptPageEdit(job, input)) {
      return Promise.resolve(false);
    }

    const previousHash = job.contentHash;

    job.accountId = bound;
    job.localRevision = Number(input.localRevision) || 0;
    bumpSyncGeneration(job, input.contentHash || null);
    job.contentHash = input.contentHash || null;
    job.payload = input.payload;

    if (job.pendingHash === job.contentHash) {
      job.pendingDirty = false;
      job.pendingHash = null;
    }

    if (job.conflict) {
      job.status = 'conflict';
      job.reason = 'conflict';
      emit();
      return Promise.resolve(true);
    }

    if (job.ackedHash && job.ackedHash === job.contentHash && job.serverDraftId && job.ackedRevision && !job.pendingDirty) {
      job.status = 'synced';
      job.reason = null;
      job.ackedGeneration = job.syncGeneration;
      emit();
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
      server_draft_id: job ? job.serverDraftId : null,
      server_revision: job && !conflict ? job.ackedRevision : null,
      conflict,
      conflict_revision: job ? job.conflictRevision : null,
      acked_hash: job ? job.ackedHash : null,
      sync_generation: job ? job.syncGeneration : null,
      tombstone: true,
      delete_state: deleteState,
      probe_hash: job && (job.sendingHash || job.probeHash || job.contentHash) || null,
    };
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

    return ledger.write({
      ...row,
      account_id: String(row.account_id),
      client_uuid: String(row.client_uuid),
      tombstone: true,
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

    if (job.conflict) {
      job.deleteState = 'blocked';
      job.status = 'conflict';
      job.reason = 'discard_blocked';
    } else if (job.ackedRevision) {
      job.deleteState = 'pending';
      job.status = 'local';
      job.reason = 'discard';
    } else if (job.probeHash) {
      job.deleteState = 'unknown';
      job.status = 'local';
      job.reason = 'discard';
    } else {
      job.deleteState = 'pending';
      job.status = 'local';
      job.reason = 'discard';
    }

    emit();

    return serial(job.clientUuid, async () => {
      if (job.deleteState === 'deleted' || job.deleteState === 'blocked' || job.conflict) {
        job.deleteState = job.conflict ? 'blocked' : job.deleteState;
        await persist(job, { tombstone: true, deleteState: job.deleteState });
        emit();
        return;
      }

      await persist(job, { tombstone: true, deleteState: job.deleteState, probeHash: job.probeHash });

      if (!current(job, epoch) || job.running) {
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
  }

  function bindAccount (accountId) {
    const next = accountId === null || accountId === undefined || accountId === '' ? null : String(accountId);

    if (next === bound) {
      return;
    }

    epoch += 1;
    bound = next;
    jobs.forEach((job) => clearTimer(job));
    jobs.clear();
  }

  async function resume (listLocal) {
    if (!bound) {
      return;
    }

    const sentEpoch = epoch;
    const accountId = bound;
    let cursors = [];

    try {
      cursors = await ledger.list(accountId);
    } catch (_error) {
      unavailable = true;
      return;
    }

    if (sentEpoch !== epoch || bound !== accountId) {
      return;
    }

    const byUuid = new Map();

    cursors.forEach((cursor) => {
      if (!cursor || String(cursor.account_id) !== accountId) {
        return;
      }

      byUuid.set(String(cursor.client_uuid), cursor);

      if (cursor.tombstone) {
        const job = ensureJob(cursor.client_uuid);

        if (!job.observed) {
          applyCursor(job, cursor);
          job.tombstone = true;
          job.accountId = accountId;

          if (cursor.conflict || cursor.delete_state === 'blocked') {
            job.conflict = true;
            job.deleteState = 'blocked';
            job.status = 'conflict';
            job.reason = 'discard_blocked';
          } else if (cursor.delete_state === 'deleted') {
            job.deleteState = 'deleted';
            job.status = 'deleted';
          } else {
            serial(job.clientUuid, () => continueDiscard(job, epoch));
          }
        }
      }
    });

    let records = [];

    try {
      records = await listLocal();
    } catch (_error) {
      unavailable = true;
      return;
    }

    if (sentEpoch !== epoch || bound !== accountId) {
      return;
    }

    (records || []).forEach((record) => {
      if (!record || String(record.account_id) !== accountId) {
        return;
      }

      const cursor = byUuid.get(String(record.client_draft_uuid));
      const existing = jobs.get(String(record.client_draft_uuid));

      if (existing && existing.observed) {
        return;
      }

      if (cursor && (cursor.tombstone || cursor.conflict)) {
        const job = ensureJob(record.client_draft_uuid);

        applyCursor(job, cursor);
        job.contentHash = record.content_hash;
        job.payload = record;
        job.localRevision = Number(record.revision) || 0;
        job.status = cursor.conflict || cursor.delete_state === 'blocked' ? 'conflict' : job.status;
        return;
      }

      const job = ensureJob(record.client_draft_uuid);

      if (cursor) {
        applyCursor(job, cursor);
      }

      if (cursor && cursor.acked_hash && cursor.acked_hash === record.content_hash && cursor.server_draft_id && !cursor.conflict) {
        job.contentHash = record.content_hash;
        job.payload = record;
        job.localRevision = Number(record.revision) || 0;
        job.syncGeneration = Number(cursor.sync_generation) || Number(cursor.acked_generation) || 0;
        job.editGeneration = job.syncGeneration;
        job.pageSession = null;
        job.pageEpoch = 0;
        job.status = 'synced';
        job.reason = null;
        return;
      }

      observeLocal({
        accountId,
        clientUuid: record.client_draft_uuid,
        localRevision: Number(record.revision) || 0,
        contentHash: record.content_hash,
        payload: record,
        editGeneration: 0,
        sessionId: 'resume',
      }, { immediate: true });
    });
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
      };
    });

    return {
      accountId: bound,
      unavailable,
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
    snapshot,
    settle,
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
