import { HISTORY_CAPABILITY, HISTORY_EDGE, WINDOW_HARD_CAP, WINDOW_TARGET } from '../constants';
import {
  applyHistoryPage,
  beginHistoryRequest,
  commitHistoryAnchor,
  failHistoryRequest,
  mergeIdLists,
  nearestRealId,
  reconcileHasMore,
  resolveCursor,
  responseIsCurrent,
  selectInitialWindow,
} from '../model';

const SNOWFLAKE = '9007199254740993';
const sequence = (count, start) => Array.from({ length: count }, (_, index) => String(start - index).padStart(6, '0'));

const loadedWindow = (items, anchorId, extra = {}) => {
  const selected = selectInitialWindow(items, anchorId, { target: 6, sourceHasMore: true, ...extra });

  return selected;
};

describe('windowed history model', () => {
  it('keeps a reading anchor instead of the newest page', () => {
    const items = sequence(40, 4000);
    const anchorId = items[25];
    const selected = selectInitialWindow(items, anchorId, { target: 8, sourceHasMore: true });

    expect(selected.items).toContain(anchorId);
    expect(selected.items[0]).not.toBe(items[0]);
    expect(selected.window.hasNewer).toBe(true);
    expect(selected.window.hasOlder).toBe(true);
    expect(selected.window.newestId).toBe(selected.items.find(id => id !== null));
    expect(selected.window.anchorResolution).toBe('exact');
    expect(selected.items.length).toBeLessThanOrEqual(8);
  });

  it('does not slice a missing anchor down to the head', () => {
    const items = sequence(30, 3000);
    const selected = selectInitialWindow(items, null, { target: 8, sourceHasMore: true });

    expect(selected.window.unbounded).toBe(true);
    expect(selected.items).toEqual(items);
    expect(selected.window.anchorResolution).toBe('unspecified');
  });

  it('resolves a vanished anchor to the older neighbor and keeps that row', () => {
    const items = ['300', '200', '100'];
    const nearest = nearestRealId(items, '250');
    const selected = selectInitialWindow(items, '250', { target: 1, sourceHasMore: false });

    expect(nearest).toEqual({ id: '200', resolution: 'nearest-older' });
    expect(selected.items).toEqual(['200']);
    expect(selected.window.anchorResolution).toBe('nearest-older');
  });

  it('keeps snowflake ids as strings', () => {
    const items = [SNOWFLAKE, '9007199254740992', '1'];
    const selected = selectInitialWindow(items, SNOWFLAKE, { target: 2, sourceHasMore: false });

    expect(selected.window.anchorId).toBe(SNOWFLAKE);
    expect(typeof selected.window.anchorId).toBe('string');
    expect(String(Number(selected.window.anchorId))).not.toBe(selected.window.anchorId);
    expect(selected.items).toContain(SNOWFLAKE);
  });

  it('does not treat a null gap or a filtered tail as the cursor', () => {
    const items = ['100', '90', null, '70', '60'];
    const windowState = selectInitialWindow(items, '90', { target: 10, sourceHasMore: true }).window;

    expect(windowState.newestId).toBe('100');
    expect(windowState.oldestId).toBe('60');
    expect(resolveCursor(items, windowState, 'older', '90')).toBe('90');
    expect(resolveCursor(items, windowState, 'older', '70')).toBe('60');
    expect(resolveCursor(items, windowState, 'newer', '60')).toBe('100');
  });

  it('trims the side farthest from the anchor and can page back', () => {
    const items = sequence(8, 800);
    const anchorId = items[6];
    let selected = loadedWindow(items, anchorId, { sourceHasMore: true });
    const started = beginHistoryRequest(selected.window, {
      direction: 'older',
      cursor: selected.window.oldestId,
      requestId: 'older-1',
      anchorId,
    });
    const page = applyHistoryPage(started.window, selected.items, {
      pageIds: ['000792', '000791', '000790'],
      direction: 'older',
      cursor: selected.window.oldestId,
      anchorId,
      limit: 3,
      target: 6,
      hardCap: 8,
    });

    expect(page.items).toContain(anchorId);
    expect(page.window.newestId).not.toBe(items[0]);
    expect(page.window.hasNewer).toBe(true);
    expect(page.window.older.status).toBe(HISTORY_EDGE.OPEN);
    expect(realLength(page.items)).toBeLessThanOrEqual(6);

    const back = beginHistoryRequest(page.window, {
      direction: 'newer',
      cursor: page.window.newestId,
      requestId: 'newer-1',
      anchorId,
    });
    const restored = applyHistoryPage(back.window, page.items, {
      pageIds: [items[0], items[1]],
      direction: 'newer',
      cursor: page.window.newestId,
      anchorId,
      capability: HISTORY_CAPABILITY.DATABASE,
      limit: 2,
      target: 6,
      hardCap: 8,
    });

    expect(restored.items[0]).toBe(items[0]);
    expect(restored.items).toContain(anchorId);
    expect(restored.window.hasOlder).toBe(true);
    expect(realLength(restored.items)).toBeLessThanOrEqual(WINDOW_TARGET);
  });

  it('marks a redis hole above the boundary as unavailable instead of finished', () => {
    const selected = selectInitialWindow(['100', '90', '80'], '80', { target: 10, sourceHasMore: true, boundaryId: '300' });
    const started = beginHistoryRequest(selected.window, {
      direction: 'newer',
      cursor: '100',
      requestId: 'newer-1',
    });
    const page = applyHistoryPage(started.window, selected.items, {
      pageIds: [],
      direction: 'newer',
      cursor: '100',
      capability: HISTORY_CAPABILITY.REDIS,
      limit: 20,
    });

    expect(page.window.newer.status).toBe(HISTORY_EDGE.UNAVAILABLE);
    expect(page.window.hasNewer).toBe(true);
    expect(page.items).toEqual(['100', '90', '80']);
  });

  it('stops newer paging at the split boundary and keeps a partial gap', () => {
    const selected = selectInitialWindow(['100', '90'], '90', { target: 10, sourceHasMore: false, boundaryId: '120' });
    const started = beginHistoryRequest(selected.window, {
      direction: 'newer',
      cursor: '100',
      requestId: 'newer-2',
    });
    const page = applyHistoryPage(started.window, selected.items, {
      pageIds: ['140', '120', '110'],
      direction: 'newer',
      cursor: '100',
      partial: true,
      capability: HISTORY_CAPABILITY.DATABASE,
      limit: 20,
    });

    expect(page.items[0]).toBe(null);
    expect(page.items).toContain('120');
    expect(page.items).not.toContain('140');
    expect(page.window.newer.status).toBe(HISTORY_EDGE.OPEN);
    expect(page.window.newestId).not.toBe(null);
  });

  it('merges a trimmed history back without dropping canonical ids', () => {
    const source = ['500', '400', null, '300', '200', '100'];
    const history = ['300', '200', '150'];
    const merged = mergeIdLists(source, history);

    expect(merged).toEqual(['500', '400', null, '300', '200', '150', '100']);
    expect(reconcileHasMore(true, source, history, {
      older: { status: HISTORY_EDGE.OPEN },
    })).toBe(true);
    expect(reconcileHasMore(true, source, ['50'], {
      older: { status: HISTORY_EDGE.EXHAUSTED },
    })).toBe(false);
  });

  it('ignores a stale generation or request and clears loading on a real failure', () => {
    const selected = selectInitialWindow(['30', '20', '10'], '20', { target: 10, sourceHasMore: true });
    const started = beginHistoryRequest(selected.window, {
      direction: 'older',
      cursor: '10',
      requestId: 'req-a',
    });
    const again = beginHistoryRequest(started.window, {
      direction: 'older',
      cursor: '10',
      requestId: 'req-b',
    });

    expect(again.accepted).toBe(false);
    expect(responseIsCurrent(started.window, { generation: 2, requestId: 'req-a', direction: 'older' })).toBe(false);
    expect(responseIsCurrent(started.window, { generation: 1, requestId: 'req-b', direction: 'older' })).toBe(false);

    const failed = failHistoryRequest(started.window, {
      generation: 1,
      requestId: 'req-a',
      direction: 'older',
    });

    expect(failed.older.status).toBe(HISTORY_EDGE.ERROR);
    expect(failed.hasOlder).toBe(true);
    expect(failHistoryRequest(started.window, { generation: 1, requestId: 'req-b', direction: 'older' })).toBe(started.window);
  });

  it('marks a short redis older page as the retained feed edge', () => {
    const selected = selectInitialWindow(['300', '290', '280'], '280', { target: 10, sourceHasMore: true });
    const started = beginHistoryRequest(selected.window, {
      direction: 'older',
      cursor: '280',
      requestId: 'older-redis',
    });
    const page = applyHistoryPage(started.window, selected.items, {
      pageIds: ['270'],
      direction: 'older',
      cursor: '280',
      capability: HISTORY_CAPABILITY.REDIS,
      limit: 20,
    });

    expect(page.window.older.status).toBe(HISTORY_EDGE.UNAVAILABLE);
    expect(page.window.hasOlder).toBe(true);
    expect(page.items).toContain('270');

    const database = applyHistoryPage(started.window, selected.items, {
      pageIds: ['270'],
      direction: 'older',
      cursor: '280',
      capability: HISTORY_CAPABILITY.DATABASE,
      limit: 20,
    });

    expect(database.window.older.status).toBe(HISTORY_EDGE.EXHAUSTED);
    expect(database.window.hasOlder).toBe(false);
  });

  it('reopens a redis older edge after a newer page trims it', () => {
    const items = sequence(12, 1200);
    const anchorId = items[6];
    const selected = selectInitialWindow(items, anchorId, { target: 5, sourceHasMore: true, boundaryId: '002000' });
    const older = beginHistoryRequest(selected.window, {
      direction: 'older',
      cursor: selected.window.oldestId,
      requestId: 'older-edge',
      anchorId,
    });
    const afterOlder = applyHistoryPage(older.window, selected.items, {
      pageIds: ['000100'],
      direction: 'older',
      cursor: selected.window.oldestId,
      anchorId,
      capability: HISTORY_CAPABILITY.REDIS,
      limit: 20,
      target: 5,
      hardCap: 8,
    });

    expect(afterOlder.window.older.status).toBe(HISTORY_EDGE.UNAVAILABLE);
    expect(afterOlder.items).toContain('000100');

    const newer = beginHistoryRequest(afterOlder.window, {
      direction: 'newer',
      cursor: afterOlder.window.newestId,
      requestId: 'newer-edge',
      anchorId,
    });
    const afterNewer = applyHistoryPage(newer.window, afterOlder.items, {
      pageIds: ['001300', '001290', '001280', '001270'],
      direction: 'newer',
      cursor: afterOlder.window.newestId,
      anchorId,
      capability: HISTORY_CAPABILITY.REDIS,
      limit: 4,
      target: 5,
      hardCap: 8,
    });

    expect(afterNewer.items).toContain(anchorId);
    expect(afterNewer.items).not.toContain('000100');
    expect(afterNewer.window.older.status).toBe(HISTORY_EDGE.OPEN);
    expect(afterNewer.window.hasOlder).toBe(true);
  });

  it('pages one direction at a time and refuses to grow an unresolved window', () => {
    const selected = selectInitialWindow(sequence(12, 1200), sequence(12, 1200)[4], { target: 8, sourceHasMore: true });
    const older = beginHistoryRequest(selected.window, {
      direction: 'older',
      cursor: selected.window.oldestId,
      requestId: 'older-1',
    });
    const newer = beginHistoryRequest(older.window, {
      direction: 'newer',
      cursor: older.window.newestId,
      requestId: 'newer-1',
    });

    expect(older.accepted).toBe(true);
    expect(newer.accepted).toBe(false);
    expect(newer.window.newer.status).not.toBe(HISTORY_EDGE.LOADING);

    const unresolved = selectInitialWindow(sequence(30, 3000), null, { target: 8, sourceHasMore: true });
    const blocked = beginHistoryRequest(unresolved.window, {
      direction: 'older',
      cursor: unresolved.window.oldestId,
      requestId: 'grow',
    });

    expect(unresolved.window.unbounded).toBe(true);
    expect(blocked.accepted).toBe(false);
  });

  it('caps an unresolved window around the middle once capture gives up', () => {
    const items = sequence(40, 4000);
    const unresolved = selectInitialWindow(items, null, { target: 8, sourceHasMore: true });
    const capped = commitHistoryAnchor(unresolved.items, unresolved.window, null, { hardCap: 10 });

    expect(capped.window.unbounded).toBe(false);
    expect(capped.window.anchorResolution).toBe('missing');
    expect(capped.items).not.toContain(items[0]);
    expect(capped.items).not.toContain(items[items.length - 1]);
    expect(realLength(capped.items)).toBeLessThanOrEqual(10);
    expect(capped.window.hasNewer).toBe(true);
    expect(capped.window.hasOlder).toBe(true);
    expect(capped.window.revision).toBe(1);
  });

  it('stays inside the hard cap after trimming the far side', () => {
    const items = sequence(WINDOW_HARD_CAP, 9000);
    const anchorId = items[WINDOW_HARD_CAP - 1];
    const selected = selectInitialWindow(items, anchorId, { target: WINDOW_TARGET, sourceHasMore: true });

    expect(selected.items).toContain(anchorId);
    expect(realLength(selected.items)).toBeLessThanOrEqual(WINDOW_TARGET);
    expect(selected.window.newestId).not.toBe(items[0]);
  });
});

const realLength = (items) => items.filter(id => typeof id === 'string').length;
