import { SEEK_KIND } from '../timeline_seek/constants';
import { createSeekQuery } from '../timeline_seek/query';
import { membershipGate } from '../timeline_text_search/session';
import { bookmarkColumnDecision } from './place';

const STALE_REASONS = ['stale', 'stale_resolve', 'stale_window', 'session_replaced', 'cancelled'];
const UNCERTAIN_REASONS = ['outside_retained_range', 'feed_regenerating', 'unknown'];

const staleResult = () => ({
  ok: false,
  moved: false,
  rollback: false,
  place: 'stale',
  reason: 'stale',
});

export const membershipRestoreDecision = (response) => {
  const gate = response && response.ok === false && response.reason && !response.body
    ? { ok: false, outcome: response.reason === 'cancelled' ? 'stale' : 'unavailable', reason: response.reason }
    : membershipGate(response, response && response.statusId);

  if (gate.outcome === 'stale' || gate.reason === 'cancelled') {
    return { action: 'ignore', place: 'stale', reason: 'stale' };
  }

  if (gate.ok) {
    return { action: 'seek', place: 'pending', reason: 'member' };
  }

  if (gate.outcome === 'unknown' || UNCERTAIN_REASONS.indexOf(gate.reason) !== -1) {
    return { action: 'stop', place: 'uncertain', reason: gate.reason || 'unknown' };
  }

  return {
    action: 'stop',
    place: 'unavailable',
    reason: gate.reason || gate.outcome || 'not_member',
  };
};

export const seekRestoreDecision = (seek, savedStatusId) => {
  const result = seek || {};
  const reason = result.reason || result.outcome || 'network';

  if (result.reason === 'resume_protected') {
    return { action: 'stop', place: 'protected', reason: 'resume_protected' };
  }

  if (STALE_REASONS.indexOf(result.outcome) !== -1 || STALE_REASONS.indexOf(result.reason) !== -1) {
    return { action: 'ignore', place: 'stale', reason: 'stale' };
  }

  if (result.outcome === 'resolved' && result.anchorId && result.anchorId === savedStatusId) {
    return { action: 'scroll', place: 'exact', reason: 'resolved' };
  }

  if (result.outcome === 'resolved' && result.anchorId && result.anchorId !== savedStatusId) {
    return { action: 'scroll', place: 'nearby', reason: result.precision || 'nearby' };
  }

  if (UNCERTAIN_REASONS.indexOf(reason) !== -1) {
    return { action: 'stop', place: 'uncertain', reason };
  }

  return { action: 'stop', place: 'unavailable', reason };
};

export const scrollRestoreDecision = ({ place, scroll } = {}) => {
  const status = scroll && (scroll.scrollStatus || scroll.reason);

  if (!scroll || status === 'stale' || scroll.reason === 'stale') {
    return { action: 'ignore', place: 'stale', reason: 'stale', rollback: false };
  }

  if (status === 'user_scroll' || scroll.reason === 'user_scroll') {
    return { action: 'leave', place: 'user_scroll', reason: 'user_scroll', rollback: false };
  }

  if (status === 'loaded') {
    return { action: 'commit', place: place === 'nearby' ? 'nearby' : 'exact', reason: 'loaded', rollback: false };
  }

  const reason = status === 'filtered' ? 'filtered' : 'not_loaded';

  return { action: 'rollback', place: 'unavailable', reason, rollback: true };
};

export const bookmarkSeekQuery = (statusId) => createSeekQuery({
  kind: SEEK_KIND.STATUS,
  target: { id: statusId },
});

const stopped = (place, reason) => ({
  ok: false,
  moved: false,
  rollback: false,
  place,
  reason,
});

const usableSnapshot = (snapshot) => !!(snapshot && snapshot.items && snapshot.windowState);

const readWindow = (captureWindow) => {
  if (typeof captureWindow !== 'function') {
    return null;
  }

  try {
    return captureWindow();
  } catch (error) {
    return null;
  }
};

// An explicit flag wins. Otherwise compare the window taken before seek with
// the window after it. A throw with no comparable pair is treated as a
// possible change so the pre-seek snapshot can still be put back.
const windowDidChange = (sought, thrown, prior, after) => {
  if (!thrown && sought && typeof sought.windowChanged === 'boolean') {
    return sought.windowChanged;
  }

  if (prior && after) {
    return prior.items !== after.items || prior.windowState !== after.windowState;
  }

  return true;
};

const seekResultOf = (thrown, sought) => {
  if (thrown || !sought) {
    return {};
  }

  return sought.result || sought;
};

const heldSnapshot = (sought, prior) => {
  if (usableSnapshot(sought && sought.snapshot)) {
    return sought.snapshot;
  }

  return usableSnapshot(prior) ? prior : null;
};

// Membership is checked immediately before seek. A saved unchecked or member
// flag does not skip it. Scroll settle is the first success. A reader scroll
// keeps the window the reader is looking at. Seek failures put the pre-seek
// history window back only when that snapshot exists, this flight is still
// current, and the reader has not scrolled.
export const runBookmarkRestore = async ({
  bookmark,
  contract,
  isCurrent,
  resumeBlocked,
  surfaceArmed,
  checkMembership,
  seek,
  markScroll,
  waitForScroll,
  rollback,
  captureReading,
  captureWindow,
  userScrolled,
  armAnchor,
  clearAnchor,
} = {}) => {
  const column = bookmarkColumnDecision(bookmark, contract);

  if (column.action === 'guide') {
    return { ...stopped('different_source', 'different_source'), guided: true };
  }

  if (column.action !== 'recheck') {
    return stopped(column.place, column.reason);
  }

  if (resumeBlocked || surfaceArmed) {
    return stopped('protected', 'resume_protected');
  }

  if (typeof isCurrent === 'function' && !isCurrent()) {
    return staleResult();
  }

  const statusId = bookmark.anchor.statusId;
  let membership;

  try {
    membership = await checkMembership(statusId);
  } catch (error) {
    if (typeof isCurrent === 'function' && !isCurrent()) {
      return staleResult();
    }

    return stopped('unavailable', 'network');
  }

  if (typeof isCurrent === 'function' && !isCurrent()) {
    return staleResult();
  }

  if (!membership) {
    return stopped('unavailable', 'network');
  }

  const gate = membershipRestoreDecision({ ...membership, statusId });

  if (gate.action === 'ignore') {
    return staleResult();
  }

  if (gate.action !== 'seek') {
    return stopped(gate.place, gate.reason);
  }

  const reading = typeof captureReading === 'function' ? captureReading() : null;
  const priorWindow = readWindow(captureWindow);
  const readerMoved = () => typeof userScrolled === 'function' && !!userScrolled();

  if (typeof armAnchor === 'function') {
    armAnchor(bookmark.anchor);
  }

  let sought = null;
  let thrown = false;

  try {
    sought = await seek(bookmarkSeekQuery(statusId));
  } catch (error) {
    thrown = true;
  }

  const afterWindow = readWindow(captureWindow);
  const snapshot = heldSnapshot(sought, priorWindow);
  const windowChanged = windowDidChange(sought, thrown, priorWindow, afterWindow);
  const result = seekResultOf(thrown, sought);

  // Old window, this flight, and no reader scroll. A window that never
  // changed is left alone. Stale work is left alone even if a snapshot exists.
  const recover = (place, reason) => {
    if (typeof clearAnchor === 'function') {
      clearAnchor();
    }

    if (typeof isCurrent === 'function' && !isCurrent()) {
      return staleResult();
    }

    if (readerMoved()) {
      return stopped('user_scroll', 'user_scroll');
    }

    if (windowChanged === false || !snapshot) {
      return stopped(place, reason);
    }

    const sessionId = (result.scroll && result.scroll.sessionId) || result.sessionId || null;

    if (typeof rollback === 'function') {
      rollback({
        snapshot,
        sessionId,
        reason: 'not_loaded',
        reading,
        replaceWindow: !sessionId,
      });
    }

    return {
      ok: false,
      moved: false,
      rollback: true,
      restored: true,
      place,
      reason,
    };
  };

  if (thrown) {
    return recover('unavailable', 'network');
  }

  if (typeof isCurrent === 'function' && !isCurrent()) {
    if (typeof clearAnchor === 'function') {
      clearAnchor();
    }

    return staleResult();
  }

  const seekDecision = seekRestoreDecision(result, statusId);

  if (seekDecision.action === 'ignore') {
    if (typeof clearAnchor === 'function') {
      clearAnchor();
    }

    return staleResult();
  }

  if (seekDecision.action !== 'scroll') {
    return recover(seekDecision.place, seekDecision.reason);
  }

  const sessionId = result.scroll && result.scroll.sessionId;

  if (!sessionId) {
    return recover('unavailable', 'not_loaded');
  }

  if (readerMoved()) {
    if (typeof clearAnchor === 'function') {
      clearAnchor();
    }

    return stopped('user_scroll', 'user_scroll');
  }

  if (typeof markScroll === 'function') {
    markScroll({ sessionId, snapshot, reading });
  }

  const scroll = await waitForScroll(sessionId);

  if (typeof clearAnchor === 'function') {
    clearAnchor();
  }

  if (typeof isCurrent === 'function' && !isCurrent()) {
    return staleResult();
  }

  const scrollDecision = scrollRestoreDecision({ place: seekDecision.place, scroll });

  if (scrollDecision.action === 'ignore') {
    return staleResult();
  }

  if (scrollDecision.action === 'leave' || readerMoved()) {
    return stopped('user_scroll', 'user_scroll');
  }

  if (scrollDecision.rollback) {
    if (typeof rollback === 'function') {
      rollback({
        snapshot,
        sessionId,
        reason: scrollDecision.reason,
        reading,
      });
    }

    return {
      ok: false,
      moved: false,
      rollback: true,
      restored: true,
      place: 'unavailable',
      reason: scrollDecision.reason,
    };
  }

  return {
    ok: true,
    moved: true,
    rollback: false,
    place: scrollDecision.place,
    reason: 'loaded',
  };
};
