import { COMPOSER_DRAFT_SCHEMA_VERSION } from './snapshot';

export const COMPOSER_DRAFT_DB_NAME = 'fedibird-composer-drafts';
export const COMPOSER_DRAFT_DB_VERSION = 2;
export const COMPOSER_DRAFT_STORE = 'drafts';
export const COMPOSER_DRAFT_SYNC_STORE = 'sync';

const recordKey = record => `${record.account_id}\u0000${record.client_draft_uuid}`;

const specified = value => value !== null && value !== undefined;

export function compareAndDelete (current, expected) {
  if (!current) {
    return { status: 'missing' };
  }

  const expectedHash = expected && expected.contentHash;
  const savedHash = expected && expected.savedHash;
  const expectedRevision = expected && expected.revision;
  const revisionMatches = specified(expectedRevision) && Number(current.revision) === Number(expectedRevision);

  // The posted body is the sent hash. The body this tab had already saved is
  // also the post when the row is still that revision. A different hash at
  // the same revision, or a newer revision, belongs to another tab and stays.
  if (specified(expectedHash) && current.content_hash === expectedHash) {
    return { status: 'deleted' };
  }

  if (specified(savedHash) && current.content_hash === savedHash && revisionMatches) {
    return { status: 'deleted' };
  }

  if (!specified(expectedHash) && !specified(savedHash) && (!specified(expectedRevision) || revisionMatches)) {
    return { status: 'deleted' };
  }

  return { status: 'kept', record: current };
}

export function unrecordedSyncBase (value) {
  return !value || value.recorded !== true;
}

export function sameSyncBase (left, right) {
  const recorded = value => Boolean(value && value.recorded === true);

  if (!recorded(left) || !recorded(right)) {
    return false;
  }

  return Number(left.revision || 0) === Number(right.revision || 0)
    && String(left.draft_id || '') === String(right.draft_id || '')
    && (left.hash || null) === (right.hash || null);
}

export function compareAndPut (current, incoming, { baseRevision = 0 } = {}) {
  if (current && String(current.account_id) !== String(incoming.account_id)) {
    return { status: 'rejected', reason: 'account_mismatch', record: current };
  }

  if (
    current
    && current.content_hash === incoming.content_hash
    && current.schema_version === incoming.schema_version
  ) {
    return { status: 'unchanged', record: current };
  }

  const currentRevision = current ? Number(current.revision) || 0 : 0;

  if (currentRevision !== baseRevision) {
    return { status: 'conflict', record: current || null };
  }

  return {
    status: 'saved',
    record: {
      ...incoming,
      schema_version: incoming.schema_version || COMPOSER_DRAFT_SCHEMA_VERSION,
      revision: currentRevision + 1,
    },
  };
}

export function isQuotaError (error) {
  if (!error) {
    return false;
  }

  return error.name === 'QuotaExceededError' || error.code === 22 || error.reason === 'quota';
}

function requestToPromise (request) {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error || new Error('indexedDB request failed'));
  });
}

export function ensureComposerDraftStores (db) {
  if (!db.objectStoreNames.contains(COMPOSER_DRAFT_STORE)) {
    const store = db.createObjectStore(COMPOSER_DRAFT_STORE, {
      keyPath: ['account_id', 'client_draft_uuid'],
    });

    store.createIndex('account_id', 'account_id', { unique: false });
  }

  if (!db.objectStoreNames.contains(COMPOSER_DRAFT_SYNC_STORE)) {
    const sync = db.createObjectStore(COMPOSER_DRAFT_SYNC_STORE, {
      keyPath: ['account_id', 'client_uuid'],
    });

    sync.createIndex('account_id', 'account_id', { unique: false });
  }
}

export function openComposerDraftDatabase (indexedDBImpl) {
  const factory = indexedDBImpl === undefined ? indexedDB : indexedDBImpl;

  return new Promise((resolve, reject) => {
    if (!factory || typeof factory.open !== 'function') {
      const error = new Error('IndexedDB is unavailable');

      error.reason = 'unavailable';
      reject(error);
      return;
    }

    let request;

    try {
      request = factory.open(COMPOSER_DRAFT_DB_NAME, COMPOSER_DRAFT_DB_VERSION);
    } catch (error) {
      error.reason = error.reason || 'unavailable';
      reject(error);
      return;
    }

    request.onerror = () => {
      const error = request.error || new Error('IndexedDB open failed');

      error.reason = error.reason || 'unavailable';
      reject(error);
    };
    request.onupgradeneeded = () => {
      ensureComposerDraftStores(request.result);
    };
    request.onsuccess = () => resolve(request.result);
  });
}

export function createIndexedDbDraftBackend ({ openDatabase = openComposerDraftDatabase } = {}) {
  let databasePromise = null;

  const database = () => {
    if (!databasePromise) {
      databasePromise = openDatabase().catch((error) => {
        databasePromise = null;
        throw error;
      });
    }

    return databasePromise;
  };

  return {
    kind: 'indexeddb',

    readDraft (accountId, clientDraftUuid) {
      return database().then(db => requestToPromise(db.transaction(COMPOSER_DRAFT_STORE, 'readonly').objectStore(COMPOSER_DRAFT_STORE).get([String(accountId), String(clientDraftUuid)])));
    },

    noteSyncBase (accountId, clientDraftUuid, previous, next, contentHash) {
      return database().then(db => new Promise((resolve, reject) => {
        const tx = db.transaction(COMPOSER_DRAFT_STORE, 'readwrite');
        const store = tx.objectStore(COMPOSER_DRAFT_STORE);
        const key = [String(accountId), String(clientDraftUuid)];
        let decision = { status: 'kept', record: null };
        const current = store.get(key);

        current.onsuccess = () => {
          const row = current.result || null;

          decision = { status: 'kept', record: row };

          if (row && row.content_hash === contentHash && (sameSyncBase(row.sync_base, previous) || unrecordedSyncBase(row.sync_base))) {
            const record = { ...row, sync_base: next };

            decision = { status: 'saved', record };
            store.put(record);
          }
        };
        current.onerror = () => reject(current.error || new Error('indexedDB get failed'));
        tx.oncomplete = () => resolve(decision);
        tx.onerror = () => reject(tx.error || new Error('indexedDB sync base failed'));
        tx.onabort = () => reject(tx.error || new Error('indexedDB sync base aborted'));
      }));
    },

    deleteDraft (accountId, clientDraftUuid, expected, extras) {
      return database().then(db => new Promise((resolve, reject) => {
        const tombstone = extras && extras.tombstone;
        const names = tombstone ? [COMPOSER_DRAFT_STORE, COMPOSER_DRAFT_SYNC_STORE] : [COMPOSER_DRAFT_STORE];
        const tx = db.transaction(names, 'readwrite');
        const store = tx.objectStore(COMPOSER_DRAFT_STORE);
        const key = [String(accountId), String(clientDraftUuid)];
        const conditional = expected && (specified(expected.contentHash) || specified(expected.savedHash) || specified(expected.revision));
        let decision = { status: 'deleted' };
        const writeTombstone = () => {
          if (!tombstone) {
            return;
          }

          const syncStore = tx.objectStore(COMPOSER_DRAFT_SYNC_STORE);
          const syncKey = [String(accountId), String(clientDraftUuid)];
          const current = syncStore.get(syncKey);

          current.onsuccess = () => {
            const merged = transitionSyncCursor(current.result || null, {
              ...tombstone,
              account_id: String(accountId),
              client_uuid: String(clientDraftUuid),
              tombstone: true,
              transition: 'discard',
            });

            decision.sync = merged;

            if (merged.accepted !== false) {
              syncStore.put(merged.record);
            }
          };
          current.onerror = () => reject(current.error || new Error('indexedDB sync get failed'));
        };

        if (!conditional) {
          store.delete(key);
          writeTombstone();
        } else {
          const getRequest = store.get(key);

          getRequest.onsuccess = () => {
            decision = compareAndDelete(getRequest.result || null, expected);

            if (decision.status === 'deleted') {
              store.delete(key);
              writeTombstone();
            }
          };
          getRequest.onerror = () => reject(getRequest.error || new Error('indexedDB get failed'));
        }

        tx.oncomplete = () => resolve(decision);
        tx.onerror = () => reject(tx.error || new Error('indexedDB delete failed'));
        tx.onabort = () => reject(tx.error || new Error('indexedDB delete aborted'));
      }));
    },

    listDrafts (accountId) {
      return database().then(db => requestToPromise(db.transaction(COMPOSER_DRAFT_STORE, 'readonly').objectStore(COMPOSER_DRAFT_STORE).index('account_id').getAll(String(accountId))));
    },

    writeDraft (incoming, options = {}) {
      return database().then(db => new Promise((resolve, reject) => {
        const tx = db.transaction(COMPOSER_DRAFT_STORE, 'readwrite');
        const store = tx.objectStore(COMPOSER_DRAFT_STORE);
        const key = [String(incoming.account_id), String(incoming.client_draft_uuid)];
        let decision = { status: 'stale' };

        const getRequest = store.get(key);

        getRequest.onsuccess = () => {
          if (options.isDiscarded && options.isDiscarded()) {
            const stored = getRequest.result || null;

            if (!stored || stored.content_hash === incoming.content_hash) {
              store.delete(key);
            }

            decision = { status: 'discarded' };
            return;
          }

          if (options.stillCurrent && !options.stillCurrent()) {
            decision = { status: 'stale' };
            return;
          }

          decision = compareAndPut(getRequest.result || null, incoming, options);

          if (options.isDiscarded && options.isDiscarded()) {
            const stored = getRequest.result || null;

            if (!stored || stored.content_hash === incoming.content_hash) {
              store.delete(key);
            }

            decision = { status: 'discarded' };
            return;
          }

          if (decision.status === 'saved') {
            if (options.stillCurrent && !options.stillCurrent()) {
              decision = { status: 'stale' };
              return;
            }

            const putRequest = store.put(decision.record);

            putRequest.onsuccess = () => {
              if (options.isDiscarded && options.isDiscarded()) {
                store.delete(key);
                decision = { status: 'discarded' };
              }
            };
            putRequest.onerror = () => {
              const error = putRequest.error || new Error('indexedDB put failed');

              if (isQuotaError(error)) {
                error.reason = 'quota';
              }

              reject(error);
            };
          }
        };
        getRequest.onerror = () => reject(getRequest.error || new Error('indexedDB get failed'));
        tx.oncomplete = () => {
          if (decision.status === 'saved' && options.isDiscarded && options.isDiscarded()) {
            resolve({ status: 'discarded' });
            return;
          }

          resolve(decision);
        };
        tx.onerror = () => {
          const error = tx.error || new Error('indexedDB write failed');

          if (isQuotaError(error)) {
            error.reason = 'quota';
          }

          reject(error);
        };
        tx.onabort = () => reject(tx.error || new Error('indexedDB write aborted'));
      }));
    },
  };
}

function intentState (source) {
  if (source.intent_state === 'unknown') {
    return 'unknown';
  }

  if (source.intent_kind) {
    return 'open';
  }

  return null;
}

function positiveInteger (value) {
  const number = Number(value);

  return Number.isInteger(number) && number > 0 ? number : null;
}

// One shape for the memory ledger and IndexedDB. A later write must not drop
// conflict, tombstone, or the send intent that an earlier put stored.
export function syncCursorRecord (record) {
  const source = record || {};

  return {
    account_id: String(source.account_id),
    client_uuid: String(source.client_uuid),
    server_draft_id: source.server_draft_id || null,
    server_revision: positiveInteger(source.server_revision),
    acked_hash: source.acked_hash || null,
    acked_generation: positiveInteger(source.acked_generation),
    sync_generation: positiveInteger(source.sync_generation),
    conflict: source.conflict === true,
    conflict_revision: positiveInteger(source.conflict_revision),
    delete_state: source.delete_state || null,
    probe_hash: source.probe_hash || null,
    tombstone: source.tombstone === true,
    intent_kind: source.intent_kind || null,
    intent_hash: source.intent_hash || null,
    intent_base_revision: positiveInteger(source.intent_base_revision),
    intent_expected_revision: positiveInteger(source.intent_expected_revision),
    intent_draft_id: source.intent_draft_id || null,
    intent_state: intentState(source),
    operation_id: source.operation_id || null,
    operation_owner: source.operation_owner || null,
    delete_revision: positiveInteger(source.delete_revision),
    delete_draft_id: source.delete_draft_id || null,
    cursor_version: cursorVersion(source.cursor_version),
  };
}

function cursorVersion (value) {
  const number = Number(value);

  return Number.isInteger(number) && number >= 0 ? number : 0;
}

function sameOperation (current, command) {
  return Boolean(current.operation_id)
    && current.operation_id === command.operation_id
    && current.operation_owner === command.operation_owner
    && current.intent_kind === command.intent_kind
    && current.intent_hash === command.intent_hash
    && Number(current.intent_base_revision || 0) === Number(command.intent_base_revision || 0)
    && Number(current.intent_expected_revision || 0) === Number(command.intent_expected_revision || 0)
    && String(current.intent_draft_id || '') === String(command.intent_draft_id || '');
}

function clearedIntent (record) {
  return {
    ...record,
    intent_kind: null,
    intent_hash: null,
    intent_base_revision: null,
    intent_expected_revision: null,
    intent_draft_id: null,
    intent_state: null,
    operation_id: null,
    operation_owner: null,
  };
}

// One accepted transition or no write. A newer acknowledgement is not lent
// to an operation that named an older base revision.
export function transitionSyncCursor (existing, command) {
  const proposed = syncCursorRecord(command);
  const action = command && command.transition;

  if (!existing) {
    if (action === 'finish' || action === 'reject' || action === 'deleted' || action === 'unknown' || action === 'conflict') {
      return {
        record: null, accepted: false, rejected: true, reason: 'missing_operation',
      };
    }

    return {
      record: { ...proposed, cursor_version: proposed.cursor_version || 1 },
      accepted: true,
      rejected: false,
      reason: action === 'claim' || action === 'discard' ? action : 'created',
    };
  }

  const current = syncCursorRecord(existing);

  if (current.delete_state === 'deleted') {
    return {
      record: current, accepted: false, rejected: true, reason: 'deleted', blocked: true,
    };
  }

  if (!action) {
    return {
      record: current, accepted: false, rejected: true, reason: 'missing_transition',
    };
  }

  const expectedVersion = cursorVersion(command.cursor_version);
  const staleCursor = expectedVersion !== current.cursor_version;

  if (staleCursor && action !== 'discard') {
    return {
      record: current, accepted: false, rejected: true, reason: 'stale_cursor',
    };
  }

  if (action === 'claim') {
    if (current.tombstone || current.conflict) {
      return {
        record: current, accepted: false, rejected: true, reason: 'protected', blocked: true,
      };
    }

    if (current.intent_kind && !sameOperation(current, command)) {
      return {
        record: current, accepted: false, rejected: true, reason: 'intent_held', heldIntent: true,
      };
    }

    if (current.intent_kind && sameOperation(current, command)) {
      return {
        record: current, accepted: true, rejected: false, reason: current.intent_state === 'unknown' ? 'unknown' : 'retry',
      };
    }

    if (Number(command.intent_base_revision || 0) !== Number(current.server_revision || 0)) {
      return {
        record: current, accepted: false, rejected: true, reason: 'stale_base',
      };
    }

    if (String(command.intent_draft_id || '') !== String(current.server_draft_id || '')) {
      return {
        record: current, accepted: false, rejected: true, reason: 'stale_base',
      };
    }

    return {
      record: {
        ...current,
        intent_kind: proposed.intent_kind,
        intent_hash: proposed.intent_hash,
        intent_base_revision: proposed.intent_base_revision,
        intent_expected_revision: proposed.intent_expected_revision,
        intent_draft_id: proposed.intent_draft_id,
        intent_state: 'open',
        operation_id: proposed.operation_id,
        operation_owner: proposed.operation_owner,
        cursor_version: current.cursor_version + 1,
      },
      accepted: true,
      rejected: false,
      reason: 'claimed',
    };
  }

  if (action === 'finish' || action === 'reject' || action === 'unknown') {
    if (!sameOperation(current, command)) {
      return {
        record: current, accepted: false, rejected: true, reason: 'intent_held', heldIntent: true,
      };
    }

    if (action === 'unknown') {
      return {
        record: {
          ...current,
          intent_state: 'unknown',
          cursor_version: current.cursor_version + 1,
        },
        accepted: true,
        rejected: false,
        reason: 'unknown',
      };
    }

    if (action === 'finish' && Number(command.server_revision) !== Number(current.intent_expected_revision)) {
      return {
        record: current, accepted: false, rejected: true, reason: 'stale_base',
      };
    }

    const finished = action === 'finish';

    return {
      record: {
        ...clearedIntent(current),
        server_revision: finished ? current.intent_expected_revision : current.server_revision,
        server_draft_id: finished ? (command.server_draft_id || current.server_draft_id) : current.server_draft_id,
        acked_hash: finished ? current.intent_hash : current.acked_hash,
        acked_generation: finished ? (positiveInteger(command.acked_generation) || current.acked_generation) : current.acked_generation,
        cursor_version: current.cursor_version + 1,
      },
      accepted: true,
      rejected: false,
      reason: finished ? 'finished' : 'rejected',
    };
  }

  if (action === 'conflict') {
    return {
      record: {
        ...current,
        conflict: true,
        conflict_revision: current.conflict_revision || proposed.conflict_revision,
        cursor_version: current.cursor_version + 1,
      },
      accepted: true,
      rejected: false,
      reason: 'conflict',
      blocked: true,
    };
  }

  if (action === 'discard') {
    if (staleCursor) {
      if (current.delete_state === 'pending' || current.delete_state === 'deleted') {
        return {
          record: current, accepted: true, rejected: false, reason: 'discarded',
        };
      }

      return {
        record: {
          ...current,
          tombstone: true,
          delete_state: current.conflict ? 'blocked' : 'unknown',
          cursor_version: current.cursor_version + 1,
        },
        accepted: true,
        rejected: false,
        reason: 'discarded',
      };
    }

    const unresolved = Boolean(current.intent_kind);
    let deleteState = 'unknown';
    let deleteRevision = current.delete_revision || positiveInteger(command.delete_revision);
    let deleteDraftId = current.delete_draft_id || command.delete_draft_id || null;

    if (current.conflict || command.conflict === true) {
      deleteState = 'blocked';
    } else if (unresolved || current.delete_state === 'unknown') {
      deleteState = 'unknown';
    } else if (deleteRevision && Number(deleteRevision) === Number(current.server_revision) && String(deleteDraftId || '') === String(current.server_draft_id || '')) {
      deleteState = 'pending';
    } else if (!current.server_revision && !deleteRevision) {
      deleteState = 'deleted';
    }

    if (current.delete_revision) {
      deleteRevision = current.delete_revision;
      deleteDraftId = current.delete_draft_id;
    }

    return {
      record: {
        ...current,
        tombstone: true,
        conflict: current.conflict || command.conflict === true,
        conflict_revision: current.conflict_revision || proposed.conflict_revision,
        delete_state: deleteState,
        delete_revision: deleteRevision,
        delete_draft_id: deleteDraftId,
        server_revision: deleteState === 'deleted' ? null : current.server_revision,
        server_draft_id: deleteState === 'deleted' ? null : current.server_draft_id,
        cursor_version: current.cursor_version + 1,
      },
      accepted: true,
      rejected: false,
      reason: 'discarded',
      blocked: deleteState === 'blocked',
    };
  }

  if (action === 'deleted') {
    if (current.intent_kind || current.delete_state === 'unknown' || current.delete_state === 'blocked') {
      return {
        record: current, accepted: false, rejected: true, reason: 'intent_held', heldIntent: Boolean(current.intent_kind),
      };
    }

    if (Number(current.delete_revision) !== Number(command.delete_revision) || Number(current.server_revision) !== Number(command.delete_revision)) {
      return {
        record: current, accepted: false, rejected: true, reason: 'stale_base',
      };
    }

    return {
      record: {
        ...clearedIntent(current),
        tombstone: true,
        delete_state: 'deleted',
        server_revision: null,
        server_draft_id: null,
        acked_hash: null,
        cursor_version: current.cursor_version + 1,
      },
      accepted: true,
      rejected: false,
      reason: 'deleted',
    };
  }

  return {
    record: current, accepted: false, rejected: true, reason: 'missing_transition',
  };
}

export function createIndexedDbSyncLedger ({ openDatabase = openComposerDraftDatabase } = {}) {
  let databasePromise = null;

  const database = () => {
    if (!databasePromise) {
      databasePromise = openDatabase().catch((error) => {
        databasePromise = null;
        throw error;
      });
    }

    return databasePromise;
  };

  return {
    read (accountId, clientUuid) {
      return database().then(db => requestToPromise(
        db.transaction(COMPOSER_DRAFT_SYNC_STORE, 'readonly').objectStore(COMPOSER_DRAFT_SYNC_STORE).get([String(accountId), String(clientUuid)]),
      ));
    },

    commit (accountId, clientUuid, proposed) {
      return database().then(db => new Promise((resolve, reject) => {
        const tx = db.transaction(COMPOSER_DRAFT_SYNC_STORE, 'readwrite');
        const store = tx.objectStore(COMPOSER_DRAFT_SYNC_STORE);
        const key = [String(accountId), String(clientUuid)];
        let merged = null;
        const current = store.get(key);

        current.onsuccess = () => {
          merged = transitionSyncCursor(current.result || null, {
            ...(proposed || {}),
            account_id: accountId,
            client_uuid: clientUuid,
          });
          const put = store.put(merged.record);

          put.onerror = () => reject(put.error || new Error('indexedDB sync put failed'));
        };
        current.onerror = () => reject(current.error || new Error('indexedDB sync get failed'));
        tx.oncomplete = () => resolve(merged);
        tx.onerror = () => reject(tx.error || new Error('indexedDB sync write failed'));
        tx.onabort = () => reject(tx.error || new Error('indexedDB sync write aborted'));
      }));
    },

    write (record) {
      return this.commit(record.account_id, record.client_uuid, record).then(merged => merged.record);
    },

    list (accountId) {
      return database().then(db => requestToPromise(
        db.transaction(COMPOSER_DRAFT_SYNC_STORE, 'readonly').objectStore(COMPOSER_DRAFT_SYNC_STORE).index('account_id').getAll(String(accountId)),
      )).then(rows => rows || []);
    },
  };
}

export function createMemoryDraftBackend () {
  const records = new Map();
  let chain = Promise.resolve();

  const exclusive = (fn) => {
    const run = chain.then(fn, fn);

    chain = run.then(() => undefined, () => undefined);

    return run;
  };

  return {
    kind: 'memory',

    readDraft (accountId, clientDraftUuid) {
      return exclusive(async () => records.get(`${accountId}\u0000${clientDraftUuid}`) || null);
    },

    noteSyncBase (accountId, clientDraftUuid, previous, next, contentHash) {
      return exclusive(async () => {
        const key = `${accountId}\u0000${clientDraftUuid}`;
        const current = records.get(key);

        if (!current || current.content_hash !== contentHash || !(sameSyncBase(current.sync_base, previous) || unrecordedSyncBase(current.sync_base))) {
          return { status: 'kept', record: current || null };
        }

        const record = { ...current, sync_base: next };

        records.set(key, record);

        return { status: 'saved', record };
      });
    },

    deleteDraft (accountId, clientDraftUuid, expected, extras) {
      return exclusive(async () => {
        const key = `${accountId}\u0000${clientDraftUuid}`;
        const conditional = expected && (specified(expected.contentHash) || specified(expected.savedHash) || specified(expected.revision));
        const finish = async (decision) => {
          if (decision.status === 'deleted' && extras && extras.tombstone && extras.writeTombstone) {
            await extras.writeTombstone({
              ...extras.tombstone,
              account_id: String(accountId),
              client_uuid: String(clientDraftUuid),
              tombstone: true,
            });
          }

          return decision;
        };

        if (!conditional) {
          records.delete(key);
          return finish({ status: 'deleted' });
        }

        const decision = compareAndDelete(records.get(key) || null, expected);

        if (decision.status === 'deleted') {
          records.delete(key);
        }

        return finish(decision);
      });
    },

    listDrafts (accountId) {
      return exclusive(async () => {
        const matched = [];

        records.forEach((record) => {
          if (String(record.account_id) === String(accountId)) {
            matched.push(record);
          }
        });

        return matched;
      });
    },

    writeDraft (incoming, options = {}) {
      return exclusive(async () => {
        if (options.beforeCommit) {
          await options.beforeCommit();
        }

        const key = recordKey(incoming);

        if (options.isDiscarded && options.isDiscarded()) {
          const current = records.get(key) || null;

          if (!current || current.content_hash === incoming.content_hash) {
            records.delete(key);
          }

          return { status: 'discarded' };
        }

        if (options.stillCurrent && !options.stillCurrent()) {
          return { status: 'stale' };
        }

        const decision = compareAndPut(records.get(key) || null, incoming, options);

        if ((options.isDiscarded && options.isDiscarded()) || (options.stillCurrent && !options.stillCurrent())) {
          return { status: 'stale' };
        }

        if (decision.status !== 'saved') {
          return decision;
        }

        if (options.failWith) {
          throw options.failWith;
        }

        records.set(key, decision.record);

        if (options.afterCommit) {
          await options.afterCommit();
        }

        if (options.isDiscarded && options.isDiscarded()) {
          records.delete(key);
          return { status: 'discarded' };
        }

        return decision;
      });
    },
  };
}
