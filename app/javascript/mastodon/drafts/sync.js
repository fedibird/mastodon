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
  const knownHashes = new Map();
  let bound = null;
  let epoch = 0;
  let inFlight = 0;
  const slotWaiters = [];
  let unavailable = false;

  const unsubscribeOnline = subscribeOnline(() => {
    jobs.forEach((job) => {
      if (job.waitingOnline) {
        job.waitingOnline = false;
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
      knownHashes.set(key, new Set());
    }

    return job;
  }

  function hashesFor (clientUuid) {
    const key = String(clientUuid);
    let known = knownHashes.get(key);

    if (!known) {
      known = new Set();
      knownHashes.set(key, known);
    }

    return known;
  }

  function clearTimer (job) {
    if (job.timer) {
      cancel(job.timer);
      job.timer = null;
    }
  }

  function scheduleJob (job, delay) {
    if (!job || job.tombstone || job.hold || job.running) {
      return;
    }

    clearTimer(job);
    job.timer = schedule(() => {
      job.timer = null;
      serial(job.clientUuid, () => push(job));
    }, delay);
  }

  function cursorFrom (job, extra = {}) {
    return {
      account_id: job.accountId,
      client_uuid: job.clientUuid,
      server_draft_id: extra.serverDraftId === undefined ? job.serverDraftId : extra.serverDraftId,
      server_revision: extra.serverRevision === undefined ? job.serverRevision : extra.serverRevision,
      acked_hash: extra.ackedHash === undefined ? job.ackedHash : extra.ackedHash,
      acked_generation: extra.ackedGeneration === undefined ? job.ackedGeneration : extra.ackedGeneration,
      tombstone: extra.tombstone === undefined ? job.tombstone === true : extra.tombstone === true,
    };
  }

  function persist (job, extra) {
    if (!job.accountId) {
      return Promise.resolve(null);
    }

    return ledger.write(cursorFrom(job, extra)).then(() => undefined, () => undefined);
  }

  function applyCursor (job, cursor) {
    if (!cursor || String(cursor.account_id) !== String(job.accountId)) {
      return;
    }

    job.serverDraftId = cursor.server_draft_id || null;
    job.serverRevision = Number(cursor.server_revision) || null;
    job.ackedHash = cursor.acked_hash || null;
    job.ackedGeneration = Number(cursor.acked_generation) || null;
    job.tombstone = cursor.tombstone === true;

    if (job.ackedHash) {
      hashesFor(job.clientUuid).add(job.ackedHash);
    }
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

  function markSynced (job, resource, sent) {
    job.serverDraftId = resource.draftId;
    job.serverRevision = resource.revision;
    job.ackedHash = sent.hash;
    job.ackedGeneration = sent.generation;
    hashesFor(job.clientUuid).add(sent.hash);
    job.attempts = 0;
    job.waitingOnline = false;

    if (job.tombstone || job.hold) {
      return;
    }

    if (job.contentHash === sent.hash && job.editGeneration === sent.generation) {
      job.status = 'synced';
      job.reason = null;
      return;
    }

    job.status = 'local';
    job.reason = 'coalesced';
    scheduleJob(job, 0);
  }

  function markConflict (job, resource) {
    if (resource) {
      job.serverDraftId = resource.draftId || job.serverDraftId;
      job.serverRevision = resource.revision || job.serverRevision;
    }

    job.status = 'conflict';
    job.reason = 'conflict';
    job.attempts = 0;
    job.waitingOnline = false;
  }

  function markFailed (job, reason) {
    job.status = 'failed';
    job.reason = reason;
    job.waitingOnline = false;
  }

  function scheduleRetry (job, sentEpoch) {
    if (!current(job, sentEpoch) || job.tombstone || job.hold) {
      return;
    }

    job.attempts += 1;

    if (job.attempts >= maxAttempts) {
      markFailed(job, 'retry_exhausted');
      return;
    }

    const delay = Math.min(retryCapMs, retryBaseMs * (2 ** (job.attempts - 1)));

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

  function produced (job, hash) {
    return Boolean(hash) && (hash === job.ackedHash || hashesFor(job.clientUuid).has(hash));
  }

  async function reconcile (job, resource, sent, sentEpoch) {
    if (!resource) {
      markConflict(job, null);
      await persist(job);
      return;
    }

    if (resource.hash && resource.hash === job.contentHash && !job.tombstone && !job.hold) {
      markSynced(job, resource, {
        hash: job.contentHash,
        generation: job.editGeneration,
      });
      await persist(job);
      return;
    }

    if (resource.hash && (resource.hash === sent.hash || produced(job, resource.hash))) {
      job.serverDraftId = resource.draftId;
      job.serverRevision = resource.revision;
      hashesFor(job.clientUuid).add(resource.hash);
      await persist(job);

      if (current(job, sentEpoch) && !job.tombstone && !job.hold && job.contentHash !== resource.hash) {
        job.status = 'local';
        job.reason = 'coalesced';
        job.attempts = 0;
        scheduleJob(job, 0);
      }

      return;
    }

    markConflict(job, resource);
    await persist(job);
  }

  async function removeServer (job, sentEpoch, followed = false) {
    if (!job.serverDraftId || !job.serverRevision) {
      job.status = 'deleted';
      job.reason = null;
      await persist(job, { tombstone: true });
      return;
    }

    const response = await call(job, {
      method: 'delete',
      path: `/api/v1/fedibird/post_drafts/${job.serverDraftId}`,
      body: { expected_revision: job.serverRevision },
    }, sentEpoch);

    if (!response || response.ignored) {
      return;
    }

    if (!current(job, sentEpoch)) {
      if (response.status === 200 || response.status === 404) {
        await ledger.write(cursorFrom(job, { tombstone: true, serverDraftId: null, serverRevision: null }));
      }

      return;
    }

    if (response.status === 200 || response.status === 404) {
      job.serverDraftId = null;
      job.serverRevision = null;
      job.status = 'deleted';
      job.reason = null;
      job.attempts = 0;
      await persist(job, { tombstone: true, serverDraftId: null, serverRevision: null });
      return;
    }

    if (response.status === 409) {
      const fetched = await readServer(job, draftResource(response.body)?.draftId || job.serverDraftId, sentEpoch);

      if (!followed && fetched && fetched.resource && produced(job, fetched.resource.hash)) {
        job.serverDraftId = fetched.resource.draftId;
        job.serverRevision = fetched.resource.revision;
        await removeServer(job, sentEpoch, true);
        return;
      }

      markConflict(job, fetched && fetched.resource);
      await persist(job, { tombstone: true });
      return;
    }

    const kind = failureKind(response);

    if (kind === 'retry') {
      scheduleRetry(job, sentEpoch);
      return;
    }

    markFailed(job, kind);
    await persist(job, { tombstone: true });
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
      await removeServer(job, sentEpoch);
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
      generation: job.editGeneration,
      payload,
    };

    job.running = true;
    job.sendingHash = sent.hash;
    job.sendingGeneration = sent.generation;
    job.status = 'syncing';
    job.reason = null;
    hashesFor(job.clientUuid).add(sent.hash);

    const creating = !job.serverDraftId;
    const response = await call(job, creating ? {
      method: 'post',
      path: '/api/v1/fedibird/post_drafts',
      body: { client_uuid: job.clientUuid, payload },
    } : {
      method: 'patch',
      path: `/api/v1/fedibird/post_drafts/${job.serverDraftId}`,
      body: { expected_revision: job.serverRevision, payload },
    }, sentEpoch);

    job.running = false;
    job.sendingHash = null;
    job.sendingGeneration = null;

    if (!response || response.ignored || !current(job, sentEpoch)) {
      if (response && !response.ignored && response.status && sent.hash) {
        const learned = draftResource(response.body);

        if (learned && learned.hash === sent.hash) {
          await ledger.write({
            account_id: job.accountId,
            client_uuid: job.clientUuid,
            server_draft_id: learned.draftId,
            server_revision: learned.revision,
            acked_hash: sent.hash,
            acked_generation: sent.generation,
            tombstone: false,
          });
        }
      }

      return;
    }

    if (job.hold) {
      const learned = draftResource(response.body);

      if (learned) {
        job.serverDraftId = learned.draftId;
        job.serverRevision = learned.revision;
        job.ackedHash = learned.hash || sent.hash;
        job.ackedGeneration = sent.generation;
      }

      job.status = 'held';
      job.reason = 'publish';
      await persist(job);
      return;
    }

    if (job.tombstone) {
      const learned = draftResource(response.body);

      if (learned) {
        job.serverDraftId = learned.draftId;
        job.serverRevision = learned.revision;
      }

      await removeServer(job, sentEpoch);
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
        job.serverRevision = null;
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
      job.serverRevision = null;
      markFailed(job, 'missing');
      await persist(job, { serverDraftId: null, serverRevision: null });
      return;
    }

    markFailed(job, kind);
    await persist(job);
  }

  function observeLocal (input, options = {}) {
    if (!input || !bound || String(input.accountId) !== String(bound)) {
      return Promise.resolve(false);
    }

    if (input.payload && String(input.payload.account_id) !== String(bound)) {
      return Promise.resolve(false);
    }

    const job = ensureJob(input.clientUuid);

    if (job.tombstone || job.hold) {
      return Promise.resolve(false);
    }

    const generation = Number(input.editGeneration) || 0;

    if (generation < job.editGeneration) {
      return Promise.resolve(false);
    }

    job.accountId = bound;
    job.editGeneration = generation;
    job.localRevision = Number(input.localRevision) || 0;
    job.contentHash = input.contentHash || null;
    job.payload = input.payload;

    if (job.ackedHash && job.ackedHash === job.contentHash && job.serverDraftId && job.ackedGeneration === generation) {
      job.status = 'synced';
      job.reason = null;
      return Promise.resolve(true);
    }

    if (job.running) {
      job.status = job.contentHash === input.contentHash ? 'syncing' : 'local';
      job.reason = job.status === 'local' ? 'coalesced' : null;
      return Promise.resolve(true);
    }

    job.status = 'local';
    job.reason = null;
    scheduleJob(job, options.immediate ? 0 : serverDebounceMs);

    return Promise.resolve(true);
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
    job.status = 'local';
    job.reason = 'discard';

    return serial(job.clientUuid, async () => {
      await persist(job, { tombstone: true });

      if (!current(job, epoch)) {
        return;
      }

      if (job.running) {
        return;
      }

      await removeServer(job, epoch);
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

      if (cursor.tombstone && cursor.server_draft_id) {
        const job = ensureJob(cursor.client_uuid);

        applyCursor(job, cursor);
        job.tombstone = true;
        serial(job.clientUuid, () => removeServer(job, epoch));
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

      if (cursor && cursor.tombstone) {
        return;
      }

      const job = ensureJob(record.client_draft_uuid);

      if (cursor) {
        applyCursor(job, cursor);
      }

      if (cursor && cursor.acked_hash && cursor.acked_hash === record.content_hash && cursor.server_draft_id) {
        job.contentHash = record.content_hash;
        job.payload = record;
        job.localRevision = Number(record.revision) || 0;
        job.editGeneration = Number(cursor.acked_generation) || Number(record.revision) || 0;
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
        editGeneration: Number(record.revision) || 1,
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
        serverRevision: job.serverRevision,
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
    noteDiscard,
    notePublish,
    resume,
    snapshot,
    settle,
    dispose () {
      unsubscribeOnline();
      jobs.forEach((job) => clearTimer(job));
    },
  };
}
