import { externalEmbedFrameProps } from './frame_props';

// One external player lives in a host node that React never renders.
// Inline rows and the fixed dock only publish rectangles. The media element
// stays a child of that host: its src, key, and parent do not change when the
// user pins, scrolls, or moves between columns. Moving it with appendChild or
// a portal is not used. Those operations are not treated as proof that a
// cross-origin document kept its session.
//
// Generic iframes have no shared play, pause, or position API. Pinning one
// keeps the same frame. Closing it, or replacing it with another pinned
// player, discards that frame. Remote audio and video do expose play, pause,
// and ended. Only a user-started playback that is still running is moved into
// the single fixed slot when its row leaves the screen. Paused and finished
// media stay paused.

export { externalEmbedFrameProps } from './frame_props';

export const IFRAME_SANDBOX = externalEmbedFrameProps.sandbox;
export const IFRAME_ALLOW = externalEmbedFrameProps.allow;
export const IFRAME_REFERRER_POLICY = externalEmbedFrameProps.referrerPolicy;

const HOST_ID = 'external-player-host';

const sessions = new Map();
const anchors = new Map();
const listeners = new Set();

let host = null;
let pinnedKey = null;
let anchorSeq = 0;
let dockSlot = null;
let attachmentFloatActive = false;
let claimHandler = null;
let listening = false;
let layoutFrame = 0;
let resizeObserver = null;
let mutationObserver = null;
const observedBoxes = new Set();
const observedTrees = new Set();
// Each anchor and the dock record the elements they need. Shared ancestors
// stay registered until every record that names them is gone.
const watchRoots = new Map();

const hasText = (value) => value !== undefined && value !== null && String(value) !== '';

export const externalPlayerKey = (statusId, mediaId) => {
  if (!hasText(statusId) || !hasText(mediaId)) {
    return null;
  }

  const status = String(statusId);
  const media = String(mediaId);
  return `${status.length}:${status}\n${media}`;
};

const emit = () => {
  listeners.forEach(listener => listener());
};

// Anchor registration runs from mount and unmount. Updating subscribers in
// that stack re-enters React, so those notifications wait until the commit
// finishes. Open, pin, and close still notify immediately from the event.
let emitQueued = false;
let emitGeneration = 0;

const emitDeferred = () => {
  if (emitQueued) {
    return;
  }

  emitQueued = true;
  const generation = emitGeneration;
  const run = () => {
    if (generation !== emitGeneration) {
      return;
    }

    emitQueued = false;
    emit();
  };

  if (typeof queueMicrotask === 'function') {
    queueMicrotask(run);
  } else {
    setTimeout(run, 0);
  }
};

export const subscribeExternalPlayers = (listener) => {
  listeners.add(listener);
  return () => listeners.delete(listener);
};

export const getSession = (key) => sessions.get(key) || null;

export const getSessionByIdentity = (statusId, mediaId) => getSession(externalPlayerKey(statusId, mediaId));

export const getPinnedKey = () => pinnedKey;

export const getPinnedSession = () => (pinnedKey ? getSession(pinnedKey) : null);

export const playerHost = () => host;

export const connectedPlayerNodes = (tag) => {
  if (!host) {
    return [];
  }

  return Array.from(host.querySelectorAll(tag));
};

const ensureHost = () => {
  if (host && host.isConnected) {
    return host;
  }

  host = document.createElement('div');
  host.id = HOST_ID;
  host.className = 'external-player-host';
  document.body.appendChild(host);
  return host;
};

const scheduleLayout = () => {
  if (layoutFrame || typeof requestAnimationFrame !== 'function') {
    return;
  }

  layoutFrame = requestAnimationFrame(() => {
    layoutFrame = 0;
    layoutAll();
  });
};

const observeBox = (element) => {
  if (!element || observedBoxes.has(element) || !resizeObserver) {
    return;
  }

  observedBoxes.add(element);
  resizeObserver.observe(element);
};

const observeTree = (element) => {
  if (!element || observedTrees.has(element) || !mutationObserver) {
    return;
  }

  observedTrees.add(element);
  mutationObserver.observe(element, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ['class', 'style'],
  });
};

// Sibling posts change the anchor's position without changing its own box.
// ResizeObserver on the anchor alone misses that. The elements are the node
// itself and each ancestor through the scrollport.
const positionContext = (element) => {
  const needed = [];

  if (!element || typeof window === 'undefined') {
    return needed;
  }

  needed.push(element);
  let node = element.parentElement;

  while (node && node !== document.documentElement) {
    needed.push(node);

    const style = window.getComputedStyle(node);
    const overflow = `${style.overflow}${style.overflowX}${style.overflowY}`;

    if (/auto|scroll/.test(overflow)) {
      break;
    }

    node = node.parentElement;
  }

  return needed;
};

const neededObservations = () => {
  const boxes = new Set();
  const trees = new Set();

  watchRoots.forEach((elements) => {
    elements.forEach((element) => {
      boxes.add(element);
      trees.add(element);
    });
  });

  return { boxes, trees };
};

const sameMembers = (left, right) => {
  if (left.size !== right.size) {
    return false;
  }

  let same = true;
  left.forEach((element) => {
    if (!right.has(element)) {
      same = false;
    }
  });
  return same;
};

// ResizeObserver can drop one target. MutationObserver cannot, so a changed
// set disconnects and observes only the targets that are still needed.
const syncLayoutObservers = () => {
  ensureLayoutWatch();
  const { boxes, trees } = neededObservations();

  Array.from(observedBoxes).forEach((element) => {
    if (boxes.has(element)) {
      return;
    }

    if (resizeObserver && typeof resizeObserver.unobserve === 'function') {
      resizeObserver.unobserve(element);
    }

    observedBoxes.delete(element);
  });
  boxes.forEach((element) => observeBox(element));

  if (!sameMembers(observedTrees, trees)) {
    if (mutationObserver) {
      mutationObserver.disconnect();
    }

    observedTrees.clear();
    trees.forEach((element) => observeTree(element));
  }
};

const setWatchRoot = (token, element) => {
  if (!element) {
    if (!watchRoots.delete(token)) {
      return;
    }

    syncLayoutObservers();
    return;
  }

  watchRoots.set(token, positionContext(element));
  syncLayoutObservers();
};

const clearWatchRoot = (token) => setWatchRoot(token, null);

const ensureLayoutWatch = () => {
  if (typeof ResizeObserver === 'function' && !resizeObserver) {
    resizeObserver = new ResizeObserver(() => scheduleLayout());
  }

  if (typeof MutationObserver === 'function' && !mutationObserver) {
    mutationObserver = new MutationObserver(() => scheduleLayout());
  }
};

const ensureListening = () => {
  if (listening || typeof window === 'undefined') {
    return;
  }

  listening = true;
  window.addEventListener('scroll', scheduleLayout, true);
  window.addEventListener('resize', scheduleLayout);
  ensureLayoutWatch();
};

const stopLayoutWatch = () => {
  if (resizeObserver) {
    resizeObserver.disconnect();
    resizeObserver = null;
  }

  if (mutationObserver) {
    mutationObserver.disconnect();
    mutationObserver = null;
  }

  observedBoxes.clear();
  observedTrees.clear();
  watchRoots.clear();
};

const stopListening = () => {
  if (typeof window !== 'undefined' && listening) {
    window.removeEventListener('scroll', scheduleLayout, true);
    window.removeEventListener('resize', scheduleLayout);
  }

  listening = false;
  stopLayoutWatch();

  if (layoutFrame && typeof cancelAnimationFrame === 'function') {
    cancelAnimationFrame(layoutFrame);
  }

  layoutFrame = 0;
};

export const setFloatingClaimHandler = (handler) => {
  claimHandler = typeof handler === 'function' ? handler : null;
};

export const setAttachmentFloatActive = (active) => {
  attachmentFloatActive = active === true;
};

const shouldAutoContinue = (session) => (
  !!session &&
  !session.closing &&
  !session.failed &&
  !session.pinned &&
  (session.kind === 'audio' || session.kind === 'video') &&
  session.userStarted === true &&
  session.paused !== true &&
  session.ended !== true
);

const pauseOwnedMedia = (session) => {
  const node = session && session.node;

  if (!node || (node.tagName !== 'AUDIO' && node.tagName !== 'VIDEO')) {
    return;
  }

  session.ignorePlayback = true;
  const jsdom = typeof navigator !== 'undefined' && /jsdom/i.test(navigator.userAgent || '');

  if (!jsdom) {
    try {
      node.pause();
    } catch (_error) {
      // The element can already be detached from media playback.
    }
  }

  session.ignorePlayback = false;
  session.paused = true;
};

const destroyNode = (session) => {
  const node = session.node;
  session.node = null;

  if (!node) {
    return;
  }

  session.ignorePlayback = true;

  if (node.tagName === 'AUDIO' || node.tagName === 'VIDEO') {
    const jsdom = typeof navigator !== 'undefined' && /jsdom/i.test(navigator.userAgent || '');

    if (!jsdom) {
      try {
        node.pause();
      } catch (_error) {
        // Already stopped.
      }
    }

    node.removeAttribute('src');

    if (!jsdom) {
      try {
        node.load();
      } catch (_error) {
        // The element can already be leaving the document.
      }
    }
  }

  node.remove();
  session.ignorePlayback = false;
};

const dropAnchors = (key) => {
  anchors.forEach((anchor, id) => {
    if (anchor.key === key) {
      anchors.delete(id);
      watchRoots.delete(`anchor:${id}`);
    }
  });
  syncLayoutObservers();
};

const endSession = (key, _reason, deferred) => {
  const session = sessions.get(key);

  if (!session || session.closing) {
    return;
  }

  session.closing = true;
  session.pinned = false;

  if (pinnedKey === key) {
    pinnedKey = null;
  }

  destroyNode(session);
  dropAnchors(key);
  sessions.delete(key);

  if (sessions.size === 0) {
    stopListening();
  }

  if (deferred) {
    emitDeferred();
  } else {
    emit();
  }

  scheduleLayout();
};

export const endExternalStatus = (statusId, reason) => {
  if (!hasText(statusId)) {
    return;
  }

  const id = String(statusId);
  Array.from(sessions.values()).forEach(session => {
    if (session.statusId === id) {
      endSession(session.key, reason);
    }
  });
};

export const endAllExternalPlayers = (reason) => {
  Array.from(sessions.keys()).forEach(key => endSession(key, reason));
};

export const endPinnedSession = (reason) => {
  if (pinnedKey) {
    endSession(pinnedKey, reason);
  }
};

const sessionForNode = (node) => {
  let found = null;
  sessions.forEach(session => {
    if (session.node === node) {
      found = session;
    }
  });
  return found;
};

const onPlay = (event) => {
  const session = sessionForNode(event.currentTarget);

  if (!session || session.closing || session.ignorePlayback) {
    return;
  }

  session.userStarted = true;
  session.paused = false;
  session.ended = false;
  emit();
};

const onPause = (event) => {
  const session = sessionForNode(event.currentTarget);

  if (!session || session.closing || session.ignorePlayback) {
    return;
  }

  session.paused = true;
  emit();
};

const onEnded = (event) => {
  const session = sessionForNode(event.currentTarget);

  if (!session || session.closing || session.ignorePlayback) {
    return;
  }

  session.ended = true;
  session.paused = true;
  emit();
};

const onError = (event) => {
  const session = sessionForNode(event.currentTarget);

  if (!session || session.closing || session.ignorePlayback || session.kind === 'iframe') {
    return;
  }

  session.failed = true;
  session.pinned = false;

  if (pinnedKey === session.key) {
    pinnedKey = null;
  }

  destroyNode(session);
  emit();
};

const createFrame = (url) => {
  const iframe = document.createElement('iframe');
  iframe.className = 'external-player-host__media';
  iframe.title = 'External video';
  iframe.setAttribute('sandbox', externalEmbedFrameProps.sandbox);
  iframe.setAttribute('allow', externalEmbedFrameProps.allow);
  iframe.setAttribute('referrerpolicy', externalEmbedFrameProps.referrerPolicy);

  if (externalEmbedFrameProps.allowFullScreen) {
    iframe.allowFullscreen = true;
  }

  // The container policy is fixed when the frame is created. Later pin and
  // inline placement only change CSS, never allow, sandbox, or src.
  iframe.src = url;
  return iframe;
};

const createRemote = (kind, url) => {
  const media = document.createElement(kind);
  media.className = 'external-player-host__media';
  media.controls = true;
  media.preload = 'none';
  media.autoplay = false;
  media.removeAttribute('autoplay');
  media.setAttribute('referrerpolicy', IFRAME_REFERRER_POLICY);

  if (kind === 'video') {
    media.playsInline = true;
  }

  media.addEventListener('play', onPlay);
  media.addEventListener('pause', onPause);
  media.addEventListener('ended', onEnded);
  media.addEventListener('error', onError);
  media.src = url;
  return media;
};

export const openSession = ({ statusId, mediaId, kind, url }) => {
  const key = externalPlayerKey(statusId, mediaId);

  if (!key || (kind !== 'iframe' && kind !== 'audio' && kind !== 'video') || !url) {
    return null;
  }

  const existing = sessions.get(key);

  if (existing && !existing.closing) {
    return existing;
  }

  const node = kind === 'iframe' ? createFrame(url) : createRemote(kind, url);
  node.setAttribute('data-external-player-key', key);
  const session = {
    key,
    statusId: String(statusId),
    mediaId: String(mediaId),
    kind,
    url,
    node,
    pinned: false,
    failed: false,
    closing: false,
    userStarted: false,
    paused: true,
    ended: false,
    ignorePlayback: false,
    anchorIds: new Set(),
    activeAnchorId: null,
    seenVisible: false,
    returnUnavailable: false,
  };

  sessions.set(key, session);
  ensureHost().appendChild(node);
  ensureListening();
  emit();
  scheduleLayout();
  return session;
};

export const pinSession = (key, options = {}) => {
  const session = sessions.get(key);

  if (!session || session.closing || session.failed || !session.node) {
    return { ok: false };
  }

  if (options.automatic && attachmentFloatActive) {
    pauseOwnedMedia(session);
    emit();
    return { ok: false, reason: 'attachment-pip' };
  }

  if (pinnedKey === key) {
    session.returnUnavailable = false;
    emit();
    scheduleLayout();
    return { ok: true, unchanged: true };
  }

  if (pinnedKey && pinnedKey !== key) {
    endSession(pinnedKey, 'replaced');
  }

  const current = sessions.get(key);

  if (!current || !current.node) {
    return { ok: false };
  }

  current.pinned = true;
  current.returnUnavailable = false;
  pinnedKey = key;

  if (!options.automatic && claimHandler) {
    claimHandler();
  }

  emit();
  scheduleLayout();
  return { ok: true };
};

export const unpinSession = (key) => {
  const session = sessions.get(key);

  if (!session || session.closing || pinnedKey !== key) {
    return { returned: false };
  }

  const alive = Array.from(session.anchorIds).some(id => anchors.has(id));

  if (!alive) {
    session.returnUnavailable = true;
    emit();
    return { returned: false, reason: 'missing-anchor' };
  }

  session.pinned = false;
  session.returnUnavailable = false;
  pinnedKey = null;
  emit();
  scheduleLayout();
  return { returned: true };
};

export const closeSession = (key) => {
  endSession(key, 'close');
};

export const dismissFailedSession = (key) => {
  const session = sessions.get(key);

  if (!session) {
    return;
  }

  session.closing = true;
  destroyNode(session);
  dropAnchors(key);

  if (pinnedKey === key) {
    pinnedKey = null;
  }

  sessions.delete(key);
  emit();
};

export const registerAnchor = ({ key, element, prefer, releaseMode }) => {
  const session = sessions.get(key);

  if (!session || session.closing || !element) {
    return null;
  }

  anchorSeq += 1;
  const id = anchorSeq;
  anchors.set(id, {
    id,
    key,
    element,
    releaseMode: typeof releaseMode === 'function' ? releaseMode : () => 'detach',
  });
  session.anchorIds.add(id);

  if (prefer || !anchors.has(session.activeAnchorId)) {
    session.activeAnchorId = id;
  }

  setWatchRoot(`anchor:${id}`, element);
  scheduleLayout();
  emitDeferred();
  return id;
};

export const updateAnchorElement = (anchorId, element) => {
  const anchor = anchors.get(anchorId);

  if (!anchor || !element) {
    return;
  }

  anchor.element = element;
  setWatchRoot(`anchor:${anchorId}`, element);
  scheduleLayout();
};

const remainingAnchors = (session) => (
  Array.from(session.anchorIds).filter(id => anchors.has(id))
);

export const unregisterAnchor = (anchorId) => {
  const anchor = anchors.get(anchorId);

  if (!anchor) {
    return;
  }

  anchors.delete(anchorId);
  clearWatchRoot(`anchor:${anchorId}`);
  const session = sessions.get(anchor.key);

  if (!session || session.closing) {
    return;
  }

  session.anchorIds.delete(anchorId);

  if (session.activeAnchorId === anchorId) {
    const rest = remainingAnchors(session);
    session.activeAnchorId = rest.length > 0 ? rest[rest.length - 1] : null;
  }

  const mode = anchor.releaseMode();

  if (mode === 'end') {
    if (remainingAnchors(session).length === 0) {
      endSession(session.key, 'end', true);
    } else {
      emitDeferred();
      scheduleLayout();
    }

    return;
  }

  if (remainingAnchors(session).length > 0) {
    emitDeferred();
    scheduleLayout();
    return;
  }

  if (session.pinned) {
    emitDeferred();
    scheduleLayout();
    return;
  }

  if (session.kind === 'iframe') {
    scheduleUnpinnedIframeEnd(session.key);
    return;
  }

  if (attachmentFloatActive) {
    pauseOwnedMedia(session);
    emitDeferred();
    scheduleLayout();
    return;
  }

  if (shouldAutoContinue(session)) {
    pinSession(session.key, { automatic: true });
    return;
  }

  emitDeferred();
  scheduleLayout();
};

// A replacement anchor in the same commit registers before this runs.
// A row that actually left the screen still has no anchor, and an unpinned
// iframe is discarded instead of staying hidden and possibly still playing.
const scheduleUnpinnedIframeEnd = (key) => {
  const generation = emitGeneration;
  const run = () => {
    if (generation !== emitGeneration) {
      return;
    }

    const session = sessions.get(key);

    if (!session || session.closing || session.pinned || session.kind !== 'iframe') {
      return;
    }

    if (remainingAnchors(session).length > 0) {
      return;
    }

    endSession(session.key, 'anchor-lost', true);
  };

  if (typeof queueMicrotask === 'function') {
    queueMicrotask(run);
  } else {
    setTimeout(run, 0);
  }
};

const releaseDockWatch = () => {
  clearWatchRoot('dock:slot');
  clearWatchRoot('dock:parent');
};

export const registerDockSlot = (element) => {
  releaseDockWatch();
  dockSlot = element || null;

  if (element) {
    setWatchRoot('dock:slot', element);

    if (element.parentElement) {
      setWatchRoot('dock:parent', element.parentElement);
    }
  }

  scheduleLayout();
  return () => {
    if (dockSlot !== element) {
      return;
    }

    dockSlot = null;
    releaseDockWatch();
  };
};

export const anchorRole = (session, anchorId) => {
  if (!session) {
    return 'closed';
  }

  if (session.failed) {
    return 'failed';
  }

  if (session.pinned) {
    return 'pinned';
  }

  if (!anchorId || session.activeAnchorId === anchorId) {
    return 'active';
  }

  return 'elsewhere';
};

const clipRect = (element) => {
  const rect = element.getBoundingClientRect();

  if (rect.width < 1 || rect.height < 1) {
    return null;
  }

  let top = rect.top;
  let left = rect.left;
  let right = rect.right;
  let bottom = rect.bottom;
  let parent = element.parentElement;

  while (parent && parent !== document.documentElement) {
    const style = window.getComputedStyle(parent);
    const overflow = `${style.overflow}${style.overflowX}${style.overflowY}`;

    if (/auto|scroll|hidden|clip/.test(overflow)) {
      const bounds = parent.getBoundingClientRect();
      top = Math.max(top, bounds.top);
      left = Math.max(left, bounds.left);
      right = Math.min(right, bounds.right);
      bottom = Math.min(bottom, bounds.bottom);
    }

    parent = parent.parentElement;
  }

  if (typeof window !== 'undefined') {
    top = Math.max(top, 0);
    left = Math.max(left, 0);
    right = Math.min(right, window.innerWidth || right);
    bottom = Math.min(bottom, window.innerHeight || bottom);
  }

  if (right - left < 1 || bottom - top < 1) {
    return null;
  }

  return {
    top,
    left,
    right,
    bottom,
    width: right - left,
    height: bottom - top,
  };
};

const place = (node, rect, clip) => {
  node.style.position = 'fixed';
  node.style.margin = '0';
  node.style.left = `${rect.left}px`;
  node.style.top = `${rect.top}px`;
  node.style.width = `${rect.width}px`;
  node.style.height = `${rect.height}px`;
  node.style.visibility = 'visible';
  node.style.pointerEvents = 'auto';
  node.style.clipPath = clip || 'none';
};

const park = (node) => {
  node.style.position = 'fixed';
  node.style.margin = '0';
  node.style.left = '0px';
  node.style.top = '0px';
  node.style.width = '160px';
  node.style.height = '90px';
  node.style.visibility = 'hidden';
  node.style.pointerEvents = 'none';
  node.style.clipPath = 'inset(100%)';
};

const considerAutoContinue = (session, element) => {
  if (!shouldAutoContinue(session) || !element || !element.isConnected) {
    return;
  }

  const full = element.getBoundingClientRect();

  if (full.width < 1 || full.height < 1) {
    return;
  }

  if (!session.seenVisible) {
    const visible = clipRect(element);

    if (visible && visible.height * visible.width > full.height * full.width * 0.5) {
      session.seenVisible = true;
    }

    return;
  }

  const visible = clipRect(element);
  const ratio = visible ? (visible.height * visible.width) / (full.height * full.width) : 0;

  if (ratio < 0.2) {
    pinSession(session.key, { automatic: true });
  }
};

const layoutSession = (session) => {
  const node = session.node;

  if (!node || node.parentNode !== host) {
    return;
  }

  if (session.pinned) {
    if (!dockSlot || !dockSlot.isConnected) {
      park(node);
      return;
    }

    const rect = dockSlot.getBoundingClientRect();

    if (rect.width < 1 || rect.height < 1) {
      park(node);
      return;
    }

    place(node, rect, 'none');
    return;
  }

  const anchor = anchors.get(session.activeAnchorId);
  const element = anchor && anchor.element;

  if (!element || !element.isConnected) {
    park(node);
    return;
  }

  considerAutoContinue(session, element);

  if (session.pinned) {
    layoutSession(session);
    return;
  }

  const full = element.getBoundingClientRect();
  const visible = clipRect(element);

  if (!visible) {
    park(node);
    return;
  }

  const insetTop = Math.max(0, visible.top - full.top);
  const insetLeft = Math.max(0, visible.left - full.left);
  const insetRight = Math.max(0, full.right - visible.right);
  const insetBottom = Math.max(0, full.bottom - visible.bottom);
  place(node, full, `inset(${insetTop}px ${insetRight}px ${insetBottom}px ${insetLeft}px)`);
};

const layoutAll = () => {
  sessions.forEach(layoutSession);
};

export const layoutExternalPlayers = () => {
  layoutAll();
};

export const applyExternalFeedControl = (parsed) => {
  if (!parsed || parsed.ok !== true) {
    return;
  }

  if (parsed.reason === 'subscription_removed') {
    // Statuses do not carry subscription_id. The control event names the
    // subscription and the later delete events name each status. Stop every
    // open external player now so a removed subscription cannot keep playing
    // until those deletes arrive.
    endAllExternalPlayers('subscription_removed');
    return;
  }

  if (parsed.reason === 'source_deleted' && parsed.statusId) {
    endExternalStatus(parsed.statusId, 'source_deleted');
  }
};

export const assignRelease = (holder, field, end) => {
  if (!holder[field]) {
    holder[field] = { mode: 'detach' };
  }

  holder[field].mode = end ? 'end' : 'detach';
  return holder[field];
};

export const spoilerConcealed = (status) => {
  if (!status || typeof status.get !== 'function') {
    return false;
  }

  const spoiler = status.get('spoiler_text');
  return status.get('hidden') === true && typeof spoiler === 'string' && spoiler.length > 0;
};

const eachId = (value, fn) => {
  if (!value) {
    return;
  }

  if (typeof value.forEach === 'function') {
    value.forEach(fn);
    return;
  }

  if (Array.isArray(value)) {
    value.forEach(fn);
  }
};

export const reduceExternalPlayerAction = (action) => {
  if (!action || !action.type) {
    return;
  }

  if (action.type === 'TIMELINE_DELETE' || action.type === 'TIMELINE_EXPIRE') {
    endExternalStatus(action.id, action.type);
    eachId(action.references, (id) => endExternalStatus(id, action.type));
    return;
  }

  if (action.type === 'STATUS_HIDE') {
    eachId(action.ids, (id) => endExternalStatus(id, 'conceal'));
    return;
  }

  if (action.type === 'PICTURE_IN_PICTURE_DEPLOY') {
    setAttachmentFloatActive(true);
    endExternalStatus(action.statusId, 'attachment-pip');
    endPinnedSession('attachment-pip');
    return;
  }

  if (action.type === 'PICTURE_IN_PICTURE_REMOVE') {
    setAttachmentFloatActive(false);
    return;
  }

  if (action.type === 'EXTERNAL_FEEDS_PERMITTED' && action.permitted !== true) {
    endAllExternalPlayers('access');
  }
};

export const playbackSnapshot = (key) => {
  const session = sessions.get(key);

  if (!session) {
    return null;
  }

  const node = session.node;
  return {
    kind: session.kind,
    pinned: session.pinned === true,
    failed: session.failed === true,
    userStarted: session.userStarted === true,
    paused: session.paused === true,
    ended: session.ended === true,
    returnUnavailable: session.returnUnavailable === true,
    anchorCount: remainingAnchors(session).length,
    src: node ? node.getAttribute('src') : null,
    parentId: node && node.parentElement ? node.parentElement.id : null,
    currentTime: node && typeof node.currentTime === 'number' ? node.currentTime : null,
    volume: node && typeof node.volume === 'number' ? node.volume : null,
    muted: node ? node.muted === true : null,
    playbackRate: node && typeof node.playbackRate === 'number' ? node.playbackRate : null,
    sandbox: node ? node.getAttribute('sandbox') : null,
    allow: node ? node.getAttribute('allow') : null,
    referrerPolicy: node ? node.getAttribute('referrerpolicy') : null,
  };
};

export const resetExternalPlayersForTests = () => {
  Array.from(sessions.values()).forEach(session => {
    session.closing = true;
    session.ignorePlayback = true;

    if (session.node) {
      session.node.remove();
      session.node = null;
    }
  });
  sessions.clear();
  anchors.clear();
  pinnedKey = null;
  dockSlot = null;
  attachmentFloatActive = false;
  claimHandler = null;
  anchorSeq = 0;
  emitGeneration += 1;
  emitQueued = false;
  stopListening();
  listeners.clear();

  if (host && host.parentNode) {
    host.parentNode.removeChild(host);
  }

  host = null;
};
