import { COMPOSER_DRAFT_SCHEMA_VERSION } from './snapshot';

export const COMPOSER_DRAFT_DB_NAME = 'fedibird-composer-drafts';
export const COMPOSER_DRAFT_DB_VERSION = 1;
export const COMPOSER_DRAFT_STORE = 'drafts';

const recordKey = record => `${record.account_id}\u0000${record.client_draft_uuid}`;

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
      const db = request.result;

      if (!db.objectStoreNames.contains(COMPOSER_DRAFT_STORE)) {
        const store = db.createObjectStore(COMPOSER_DRAFT_STORE, {
          keyPath: ['account_id', 'client_draft_uuid'],
        });

        store.createIndex('account_id', 'account_id', { unique: false });
      }
    };
    request.onsuccess = () => resolve(request.result);
  });
}

function runTransaction (db, mode, perform) {
  return new Promise((resolve, reject) => {
    const tx = db.transaction(COMPOSER_DRAFT_STORE, mode);
    const store = tx.objectStore(COMPOSER_DRAFT_STORE);
    let result;

    try {
      result = perform(store, (value) => {
        result = value;
      });
    } catch (error) {
      reject(error);
      return;
    }

    tx.oncomplete = () => resolve(result);
    tx.onerror = () => reject(tx.error || new Error('indexedDB transaction failed'));
    tx.onabort = () => reject(tx.error || new Error('indexedDB transaction aborted'));
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

    deleteDraft (accountId, clientDraftUuid) {
      return database().then(db => runTransaction(db, 'readwrite', (store) => {
        store.delete([String(accountId), String(clientDraftUuid)]);
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
            store.delete(key);
            decision = { status: 'discarded' };
            return;
          }

          if (options.stillCurrent && !options.stillCurrent()) {
            decision = { status: 'stale' };
            return;
          }

          decision = compareAndPut(getRequest.result || null, incoming, options);

          if (decision.status === 'saved') {
            if ((options.isDiscarded && options.isDiscarded()) || (options.stillCurrent && !options.stillCurrent())) {
              decision = { status: 'stale' };
              return;
            }

            const putRequest = store.put(decision.record);

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

    deleteDraft (accountId, clientDraftUuid) {
      return exclusive(async () => {
        records.delete(`${accountId}\u0000${clientDraftUuid}`);
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
          records.delete(key);
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

        if (options.isDiscarded && options.isDiscarded()) {
          records.delete(key);
          return { status: 'discarded' };
        }

        return decision;
      });
    },
  };
}
