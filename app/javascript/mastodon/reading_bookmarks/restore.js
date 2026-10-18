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

// Membership is checked immediately before seek. A saved unchecked or member
// flag does not skip it. Scroll settle is the first success. A reader scroll
// keeps the window the reader is looking at.
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

  if (typeof armAnchor === 'function') {
    armAnchor(bookmark.anchor);
  }

  let sought;

  try {
    sought = await seek(bookmarkSeekQuery(statusId));
  } catch (error) {
    if (typeof clearAnchor === 'function') {
      clearAnchor();
    }

    if (typeof isCurrent === 'function' && !isCurrent()) {
      return staleResult();
    }

    return stopped('unavailable', 'network');
  }

  if (typeof isCurrent === 'function' && !isCurrent()) {
    if (typeof clearAnchor === 'function') {
      clearAnchor();
    }

    return staleResult();
  }

  const result = sought && sought.result ? sought.result : (sought || {});
  const seekDecision = seekRestoreDecision(result, statusId);

  if (seekDecision.action === 'ignore') {
    if (typeof clearAnchor === 'function') {
      clearAnchor();
    }

    return staleResult();
  }

  if (seekDecision.action !== 'scroll') {
    if (typeof clearAnchor === 'function') {
      clearAnchor();
    }

    return stopped(seekDecision.place, seekDecision.reason);
  }

  const sessionId = result.scroll && result.scroll.sessionId;

  if (!sessionId) {
    if (typeof clearAnchor === 'function') {
      clearAnchor();
    }

    return stopped('unavailable', 'not_loaded');
  }

  if (typeof markScroll === 'function') {
    markScroll({ sessionId, snapshot: sought.snapshot, reading });
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

  if (scrollDecision.action === 'leave') {
    return stopped('user_scroll', 'user_scroll');
  }

  if (scrollDecision.rollback) {
    if (typeof rollback === 'function') {
      rollback({
        snapshot: sought.snapshot,
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
