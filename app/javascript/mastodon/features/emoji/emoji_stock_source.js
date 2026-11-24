import api from 'mastodon/api';
import initialState from 'mastodon/initial_state_data';
import { emptyEmojiStock, prepareEmojiStock } from './emoji_stock';

const endpoint = '/api/v1/emoji_sets/personal/stock';
const me = initialState?.meta?.me;
const pickerEmojiSize = initialState?.meta?.picker_emoji_size;
const personalStockDisabled = initialState?.meta?.emoji_picker_disable_personal === true;
const changeKey = `mastodon:personal-emoji-set:${me || 'anonymous'}`;
const stockListeners = new Set();
const sizeListeners = new Set();
let cachedDocument = null;
let etag = null;
let request = null;
let latestRequest = null;
let generation = 0;
// Highest revision applied from a trusted response. A storage marker is only
// a signal to revalidate; it is not a revision and never rejects a save.
let knownRevision = null;
let revalidationPromise = null;
let queuedSave = null;
// The next stock read resolves a marker invalidation. Listener type does not
// matter: stock-only, size-only, and a later load with no listener all share it.
let protectNextRead = false;
let listening = false;
let currentSize = Number(pickerEmojiSize) || 22;

function changeMarker() {
  try {
    return localStorage.getItem(changeKey);
  } catch (error) {
    return null;
  }
}

// Do not even read personal-set storage markers for standard-only sessions.
let lastChange = personalStockDisabled ? null : changeMarker();

const ready = document => ({ status: 'ready', stock: document.stock });

// A warm stock is safe to paint immediately. Callers still revalidate with
// ETag in the background and never persist private stock to browser storage.
export function getCachedPersonalEmojiStock() {
  if (personalStockDisabled) {
    return null;
  }

  // A different tab may have saved while no picker was mounted, and therefore
  // while the storage listener was detached. Never paint that stale cache.
  if (changeMarker() !== lastChange) {
    return null;
  }

  return cachedDocument ? ready(cachedDocument) : null;
}

function currentResult() {
  if (cachedDocument) {
    return ready(cachedDocument);
  }

  // Keep the latest outcome even after its in-flight slot has been released.
  // A superseded read must not start a new request after that outcome failed.
  return latestRequest || { status: 'error', error: new Error('Personal emoji stock was invalidated') };
}

function applySize(value) {
  if (!Number.isInteger(value) || value < 22 || value > 48 || currentSize === value) {
    return;
  }

  currentSize = value;
  sizeListeners.forEach(listener => listener(value));
}

function validateDocument(document) {
  if (!document || !document.stock || !Array.isArray(document.stock.categories)) {
    throw new Error('Invalid personal emoji stock response');
  }

  return document;
}

function noteRevision(revision) {
  if (!Number.isInteger(revision)) {
    return;
  }

  if (!Number.isInteger(knownRevision) || revision > knownRevision) {
    knownRevision = revision;
  }
}

// Generation counts invalidations. It does not order saves. Only a smaller
// revision is an older document.
function revisionIsOlder(revision) {
  return Number.isInteger(revision) && Number.isInteger(knownRevision) && revision < knownRevision;
}

function watchRevalidation(promise) {
  revalidationPromise = promise;
  promise.then(result => {
    if (revalidationPromise !== promise) {
      return;
    }

    revalidationPromise = null;
    const queued = queuedSave;
    queuedSave = null;
    const applied = cachedDocument && cachedDocument.revision;

    // A failed or non-authoritative read must not publish the queued snapshot.
    // A queued save is applied only when the read succeeded and this commit is
    // newer than the document that read just stored.
    if (result && result.status === 'ready' && queued && Number.isInteger(queued.revision) && Number.isInteger(applied) && queued.revision > applied) {
      notifySavedPersonalEmojiSet(queued);
    }
  }, () => {
    if (revalidationPromise !== promise) {
      return;
    }

    revalidationPromise = null;
    queuedSave = null;
  }).catch(() => {});
}

function queueSave(saved) {
  if (!queuedSave || (Number.isInteger(saved.revision) && (!Number.isInteger(queuedSave.revision) || saved.revision > queuedSave.revision))) {
    queuedSave = saved;
  }
}

// A marker written while nothing was listening is still a newer invalidation.
// Detect it before a save response is allowed to replace the cache.
function noteUnseenMarker() {
  const marker = changeMarker();

  if (marker === lastChange || revalidationPromise) {
    return;
  }

  lastChange = marker;
  protectNextRead = true;
  generation += 1;
  request = null;
  latestRequest = null;
  cachedDocument = null;
  etag = null;
  loadPersonalEmojiStock().catch(() => {});
}

// Each open revalidates with the server. Revision protects writes; ETag also
// reflects custom image, availability and search metadata changes. Concurrent
// pickers share the request, never a full custom or Unicode catalog request.
export function loadPersonalEmojiStock() {
  // Defense in depth: an unexpected caller must not fetch or prepare stock.
  if (personalStockDisabled) {
    return Promise.resolve({ status: 'ready', stock: emptyEmojiStock() });
  }

  if (!me && !initialState?.meta?.access_token) {
    return Promise.resolve({ status: 'ready', stock: emptyEmojiStock() });
  }

  // An editor in another tab might have changed the set while all pickers
  // were closed and the storage listener detached. Invalidate before
  // conditional requests, even for standalone picker hosts.
  const marker = changeMarker();

  if (marker !== lastChange) {
    handleStorage({ key: changeKey, newValue: marker });
  }

  if (request) {
    return request;
  }

  const protect = protectNextRead;
  protectNextRead = false;
  const requestedGeneration = generation;
  const headers = {};
  const accessToken = initialState?.meta?.access_token;

  if (accessToken) {
    headers.Authorization = `Bearer ${accessToken}`;
  }

  if (etag && cachedDocument) {
    headers['If-None-Match'] = etag;
  }

  const pending = api().get(endpoint, {
    headers,
    validateStatus: status => (status >= 200 && status < 300) || status === 304,
  }).then(response => {
    // A save or another tab's notification supersedes an older read. Resolve
    // its callers to the newer value as well as refusing to replace the cache.
    if (requestedGeneration !== generation) {
      return currentResult();
    }

    if (response.status !== 304) {
      const incoming = validateDocument(response.data);

      if (revisionIsOlder(incoming.revision)) {
        if (cachedDocument) {
          return ready(cachedDocument);
        }

        return { status: 'error', error: new Error('Personal emoji stock was superseded') };
      }

      noteRevision(incoming.revision);
      cachedDocument = incoming;
      prepareEmojiStock(cachedDocument.stock);
      etag = response.headers?.etag || null;
    }

    if (!cachedDocument) {
      throw new Error('Personal emoji stock cache is missing');
    }

    applySize(cachedDocument.picker_emoji_size);
    return ready(cachedDocument);
  }, error => {
    if (requestedGeneration !== generation) {
      return currentResult();
    }

    throw error;
  }).finally(() => {
    if (request === pending) {
      request = null;
    }
  });

  request = pending;
  latestRequest = pending;

  if (protect) {
    watchRevalidation(pending);
  }

  return pending;
}

function handleStorage(event) {
  if (event.key !== changeKey) {
    return;
  }

  // The receiving document already has the new storage value. Prefer that over
  // the event payload so a later save does not see a second, unseen marker.
  const marker = changeMarker();
  lastChange = marker === null ? event.newValue : marker;
  protectNextRead = true;
  generation += 1;
  request = null;
  latestRequest = null;
  cachedDocument = null;
  etag = null;
  stockListeners.forEach(listener => listener(null));

  // One read for an open picker, whether it subscribed to stock or to size.
  // With no listener, the next loadPersonalEmojiStock still consumes protectNextRead.
  if (stockListeners.size > 0 || sizeListeners.size > 0) {
    loadPersonalEmojiStock().catch(() => {});
  }
}

function updateStorageListener() {
  const needed = stockListeners.size > 0 || sizeListeners.size > 0;

  if (needed === listening) {
    return;
  }

  listening = needed;

  if (needed) {
    window.addEventListener('storage', handleStorage);
  } else {
    window.removeEventListener('storage', handleStorage);
  }
}

export function subscribePersonalEmojiStock(listener) {
  if (personalStockDisabled) {
    return () => {};
  }
  stockListeners.add(listener);
  updateStorageListener();

  return () => {
    stockListeners.delete(listener);
    updateStorageListener();
  };
}

export function getPickerEmojiSize() {
  return currentSize;
}

export function subscribePickerEmojiSize(listener) {
  if (personalStockDisabled) {
    return () => {};
  }
  sizeListeners.add(listener);
  updateStorageListener();

  // Dropdowns unmount while closed. Notice saves made in another tab during
  // that gap, including when the next opening uses the standard mode.
  const marker = changeMarker();

  if (marker !== lastChange) {
    handleStorage({ key: changeKey, newValue: marker });
  }

  return () => {
    sizeListeners.delete(listener);
    updateStorageListener();
  };
}

// Only call after a successful atomic save. Drafts never replace the live
// stock. A tiny change marker reaches other tabs and embedded settings frames;
// definitions and access tokens are never stored in localStorage.
export function personalEmojiStockGeneration() {
  return generation;
}

// A committed save publishes even if a storage event already moved generation.
// That counter only invalidates reads. Revision decides which document is newer,
// including after the cache was cleared. An older revision never replaces stock
// or the shared picker size, and does not write another tab marker.
export function personalEmojiDocumentIsCurrent(document) {
  if (!document || !Number.isInteger(document.revision) || revalidationPromise) {
    return false;
  }

  return !revisionIsOlder(document.revision);
}

export function notifySavedPersonalEmojiSet(document) {
  if (personalStockDisabled) {
    return false;
  }
  const saved = validateDocument(document);

  noteUnseenMarker();

  if (revisionIsOlder(saved.revision)) {
    return false;
  }

  // An invalidation is already revalidating. Keep this commit queued and let
  // that GET finish; bumping generation here would discard the newer read.
  if (revalidationPromise) {
    queueSave(saved);
    return false;
  }

  // Same revision after another tab cleared the cache is not a newer commit.
  // Leave the cache empty so the next read revalidates instead of broadcasting
  // the copy we already knew.
  if (!cachedDocument && Number.isInteger(saved.revision) && saved.revision === knownRevision) {
    return false;
  }

  noteRevision(saved.revision);
  generation += 1;
  request = null;
  latestRequest = null;
  cachedDocument = saved;
  prepareEmojiStock(saved.stock);
  etag = null;
  applySize(saved.picker_emoji_size);
  stockListeners.forEach(listener => listener(ready(saved)));

  try {
    lastChange = `${saved.revision}:${Date.now()}:${Math.random()}`;
    localStorage.setItem(changeKey, lastChange);
  } catch (error) {
    // Storage may be disabled. Same-page updates and next-open revalidation
    // still work and the successful server save must not become a UI failure.
  }

  return true;
}
