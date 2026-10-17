import { createTimelinePosition, sameTimelineSource, sameTimelineView } from '../timeline_navigation';
import { HISTORY_POSITION_MAX_ENTRIES, HISTORY_POSITION_TTL_MS } from './constants';

const accountKey = (value) => {
  if (typeof value === 'string' && value.length > 0 && value.length <= 64) {
    return value;
  }

  return null;
};

const copyRecord = (record) => ({
  accountId: record.accountId,
  position: record.position,
  hostKind: record.hostKind,
  layout: record.layout,
  routeEntryKey: record.routeEntryKey,
  updatedAt: record.updatedAt,
  holdRequestId: record.holdRequestId,
});

// In-memory session registry. One entry is a TimelinePositionV1 plus the host
// and route entry it was captured on. Status text, tokens, and page bodies
// are not accepted.
export const createPositionRegistry = ({
  now = Date.now,
  maxEntries = HISTORY_POSITION_MAX_ENTRIES,
  ttlMs = HISTORY_POSITION_TTL_MS,
} = {}) => {
  let entries = [];
  let seenAccountId = null;

  const prune = (at) => {
    const current = typeof at === 'number' ? at : now();

    entries = entries.filter(record => current - record.updatedAt <= ttlMs);
  };

  const findIndex = (accountId, source, view) => entries.findIndex(record => (
    record.accountId === accountId
    && sameTimelineSource(record.position.source, source)
    && sameTimelineView(record.position.view, view)
  ));

  return {
    noteAccount(accountId) {
      const next = accountKey(accountId);

      if (!next) {
        entries = [];
        seenAccountId = null;
        return null;
      }

      if (seenAccountId && seenAccountId !== next) {
        entries = [];
      }

      seenAccountId = next;
      return next;
    },

    accountId() {
      return seenAccountId;
    },

    record({
      accountId,
      source,
      view,
      anchor,
      hostKind = 'history',
      layout = 'single',
      routeEntryKey = null,
      requestId = null,
      sync = false,
      minIntervalMs = 0,
      at,
    } = {}) {
      const account = this.noteAccount(accountId);
      const capturedAt = typeof at === 'number' ? at : now();

      prune(capturedAt);

      if (!account) {
        return { ok: false, reason: 'account' };
      }

      const built = createTimelinePosition({ source, view, anchor });

      if (!built.ok) {
        return built;
      }

      if (hostKind !== 'history' && hostKind !== 'document' && hostKind !== 'pane' && hostKind !== 'live') {
        return { ok: false, reason: 'invalid' };
      }

      if (layout !== 'single' && layout !== 'columns') {
        return { ok: false, reason: 'invalid' };
      }

      const index = findIndex(account, built.position.source, built.position.view);
      const previous = index === -1 ? null : entries[index];

      if (previous && previous.holdRequestId && previous.holdRequestId !== requestId) {
        return { ok: false, reason: 'restore_hold', preserved: true };
      }

      if (!sync && previous && minIntervalMs > 0 && capturedAt - previous.updatedAt < minIntervalMs) {
        return { ok: false, reason: 'throttled', preserved: true };
      }

      const next = {
        accountId: account,
        position: built.position,
        hostKind,
        layout,
        routeEntryKey: typeof routeEntryKey === 'string' ? routeEntryKey : (view && view.locationKey) || null,
        updatedAt: capturedAt,
        holdRequestId: previous ? previous.holdRequestId : null,
      };

      if (index !== -1) {
        entries.splice(index, 1);
      }

      entries.push(next);

      if (entries.length > maxEntries) {
        entries.sort((left, right) => left.updatedAt - right.updatedAt);
        entries = entries.slice(entries.length - maxEntries);
      }

      return { ok: true, record: copyRecord(next) };
    },

    find(accountId, source, view, at) {
      const account = accountKey(accountId);

      prune(typeof at === 'number' ? at : now());

      if (!account || account !== seenAccountId) {
        return null;
      }

      const index = findIndex(account, source, view);

      if (index === -1) {
        return null;
      }

      return copyRecord(entries[index]);
    },

    hold(accountId, source, view, requestId) {
      const account = accountKey(accountId);
      const index = account ? findIndex(account, source, view) : -1;

      if (index === -1 || typeof requestId !== 'string' || requestId.length === 0) {
        return { ok: false, reason: 'absent' };
      }

      entries[index] = {
        ...entries[index],
        holdRequestId: requestId,
      };

      return { ok: true };
    },

    releaseHoldByRequest(requestId) {
      if (typeof requestId !== 'string' || requestId.length === 0) {
        return false;
      }

      let released = false;

      entries = entries.map(record => {
        if (record.holdRequestId !== requestId) {
          return record;
        }

        released = true;

        return {
          ...record,
          holdRequestId: null,
        };
      });

      return released;
    },

    releaseHold(accountId, source, view, requestId) {
      const account = accountKey(accountId);
      const index = account ? findIndex(account, source, view) : -1;

      if (index === -1) {
        return { ok: false, reason: 'absent' };
      }

      if (entries[index].holdRequestId && entries[index].holdRequestId !== requestId) {
        return { ok: false, reason: 'restore_hold' };
      }

      entries[index] = {
        ...entries[index],
        holdRequestId: null,
      };

      return { ok: true };
    },

    evictView(accountId, source, view) {
      const account = accountKey(accountId);
      const index = account ? findIndex(account, source, view) : -1;

      if (index === -1) {
        return false;
      }

      entries.splice(index, 1);
      return true;
    },

    evictAccount(accountId) {
      const account = accountKey(accountId);

      if (!account) {
        return 0;
      }

      const before = entries.length;

      entries = entries.filter(record => record.accountId !== account);

      if (seenAccountId === account) {
        seenAccountId = null;
      }

      return before - entries.length;
    },

    clear() {
      entries = [];
      seenAccountId = null;
    },

    size() {
      prune(now());
      return entries.length;
    },
  };
};
