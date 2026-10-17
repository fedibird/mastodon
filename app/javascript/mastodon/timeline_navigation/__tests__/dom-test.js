import {
  captureTimelineAnchor,
  findLoadedTimelineStatus,
  legacySplitAnchorFromCapture,
  restoreTimelineAnchor,
  scheduleTimelineAnchorFrames,
  scrollToLoadedTimelineStatus,
} from '../dom';
import { TIMELINE_ANCHOR_REASONS, decodeTimelineAnchor } from '../anchor';
import {
  BOOST_ORIGINAL_ID,
  BOOST_WRAPPER_ID,
  SNOWFLAKE_OVER_53_BITS,
  createTimelineHost,
  mountStickyHeader,
  rowTop,
} from '../test_fixtures';

const heights = (ids, height = 120) => ids.map(statusId => ({ statusId, height }));

const documentScroller = () => document.scrollingElement || document.body;

afterEach(() => {
  document.body.innerHTML = '';
  documentScroller().scrollTop = 0;
});

describe('captureTimelineAnchor', () => {
  it('captures the display row that crosses the sticky header, not a boost original id', () => {
    mountStickyHeader(0, 64);
    const host = createTimelineHost({
      kind: 'document',
      origin: 0,
      rows: [
        { statusId: '100', height: 40 },
        { statusId: BOOST_WRAPPER_ID, height: 100, innerStatusId: BOOST_ORIGINAL_ID },
        { statusId: SNOWFLAKE_OVER_53_BITS, height: 100 },
      ],
    });
    const anchor = captureTimelineAnchor({
      scrollHost: host.scrollHost,
      visibleTop: 64,
      alignment: 'top',
      capturedAt: '2026-10-17T03:31:02.000Z',
    });

    expect(anchor.statusId).toBe(BOOST_WRAPPER_ID);
    expect(anchor.displayRowId).toBe(BOOST_WRAPPER_ID);
    expect(typeof anchor.statusId).toBe('string');
    expect(anchor.statusId).not.toBe(BOOST_ORIGINAL_ID);
    expect(anchor.offsetPx).toBe(-24);
    expect(anchor.version).toBe(1);
    expect(anchor.capturedAt).toBe('2026-10-17T03:31:02.000Z');
    expect(anchor.fallbackScrollTop).toBe(0);
  });

  it('preserves a featured display row id for the legacy split adapter', () => {
    const host = createTimelineHost({
      kind: 'history',
      origin: 0,
      scrollTop: 20,
      rows: [{ statusId: 'f-90', height: 100 }, { statusId: '80', height: 100 }],
    });
    const captured = captureTimelineAnchor({ scrollHost: host.scrollHost, alignment: 'top' });
    const legacy = legacySplitAnchorFromCapture(captured, { fallbackOffset: 20, target: 'document' });

    expect(captured.statusId).toBeNull();
    expect(captured.displayRowId).toBe('f-90');
    expect(legacy).toEqual({ id: 'f-90', offset: -20, fallbackOffset: 20, target: 'document' });
    expect(decodeTimelineAnchor({
      version: 1,
      statusId: captured.displayRowId,
      offsetPx: captured.offsetPx,
      alignment: 'top',
    }).ok).toBe(false);
  });

  it('reports an empty capture for a gap-only host without moving scroll', () => {
    const host = createTimelineHost({
      kind: 'history',
      origin: 120,
      scrollTop: 80,
      rows: [{ gap: true, height: 48 }, { gap: true, height: 48 }],
    });
    const anchor = captureTimelineAnchor({ scrollHost: host.scrollHost, alignment: 'top' });

    expect(anchor.statusId).toBeNull();
    expect(anchor.displayRowId).toBeNull();
    expect(anchor.offsetPx).toBe(0);
    expect(host.scroller.scrollTop).toBe(80);
  });
});

describe('scrollToLoadedTimelineStatus', () => {
  it('moves only the requested pane when another pane has the same ids', () => {
    const live = createTimelineHost({
      kind: 'live',
      origin: 40,
      rows: heights(['100', '90', '80']),
    });
    const history = createTimelineHost({
      kind: 'history',
      origin: 320,
      rows: heights(['100', '90', '80']),
    });
    const moved = scrollToLoadedTimelineStatus({
      scrollHost: history.scrollHost,
      statusId: '80',
      alignment: 'top',
    });

    expect(moved.ok).toBe(true);
    expect(moved.anchor.statusId).toBe('80');
    expect(history.scroller.scrollTop).toBe(240);
    expect(rowTop(history, '80') - 320).toBe(0);
    expect(live.scroller.scrollTop).toBe(0);
    expect(rowTop(live, '80')).toBe(280);
  });

  it('centers a loaded row in a document host under the sticky header', () => {
    mountStickyHeader(0, 64);
    const host = createTimelineHost({
      kind: 'document',
      origin: 64,
      viewport: 600,
      rows: [{ statusId: '11', height: 800 }, { statusId: '12', height: 100 }],
    });
    const moved = scrollToLoadedTimelineStatus({
      scrollHost: host.scrollHost,
      visibleTop: 64,
      statusId: '12',
      alignment: 'center',
    });
    const center = 64 + ((window.innerHeight - 64) / 2);

    expect(moved.ok).toBe(true);
    expect(rowTop(host, '12') + 50).toBeCloseTo(center);
    expect(moved.anchor.statusId).toBe('12');
  });

  it('does not change scroll when the row is missing, unloaded, or the host is empty', () => {
    const host = createTimelineHost({
      kind: 'pane',
      origin: 20,
      scrollTop: 140,
      rows: [{ gap: true, height: 30 }, ...heights(['100', '90'])],
    });
    const before = host.scroller.scrollTop;
    const missing = scrollToLoadedTimelineStatus({
      scrollHost: host.scrollHost,
      statusId: '70',
      loadedStatusIds: ['100', '90', '80', '70'],
    });
    const unloaded = scrollToLoadedTimelineStatus({
      scrollHost: host.scrollHost,
      statusId: SNOWFLAKE_OVER_53_BITS,
      loadedStatusIds: ['100', '90'],
    });
    const emptyHost = createTimelineHost({ kind: 'pane', origin: 0, scrollTop: 33, rows: [{ gap: true, height: 20 }] });
    const empty = scrollToLoadedTimelineStatus({ scrollHost: emptyHost.scrollHost, statusId: '100' });

    expect(missing).toEqual({ ok: false, reason: TIMELINE_ANCHOR_REASONS.NOT_FOUND });
    expect(unloaded).toEqual({ ok: false, reason: TIMELINE_ANCHOR_REASONS.NOT_LOADED });
    expect(empty).toEqual({ ok: false, reason: TIMELINE_ANCHOR_REASONS.EMPTY });
    expect(host.scroller.scrollTop).toBe(before);
    expect(emptyHost.scroller.scrollTop).toBe(33);
    expect(scrollToLoadedTimelineStatus({ scrollHost: host.scrollHost, statusId: 100 }).reason).toBe(TIMELINE_ANCHOR_REASONS.INVALID);
    expect(findLoadedTimelineStatus({ scrollHost: { kind: 'pane', list: null, scroller: null }, statusId: '100' }).reason).toBe(TIMELINE_ANCHOR_REASONS.MISSING_HOST);
  });

  it('keeps a 19-digit boost wrapper id exact while ignoring the original status id', () => {
    const host = createTimelineHost({
      kind: 'pane',
      origin: 0,
      rows: [
        { statusId: '100', height: 80 },
        { statusId: BOOST_WRAPPER_ID, height: 160, innerStatusId: BOOST_ORIGINAL_ID },
      ],
    });
    const original = scrollToLoadedTimelineStatus({ scrollHost: host.scrollHost, statusId: BOOST_ORIGINAL_ID });

    expect(original.reason).toBe(TIMELINE_ANCHOR_REASONS.NOT_FOUND);
    expect(host.scroller.scrollTop).toBe(0);

    const wrapper = scrollToLoadedTimelineStatus({ scrollHost: host.scrollHost, statusId: BOOST_WRAPPER_ID });
    expect(wrapper.ok).toBe(true);
    expect(wrapper.anchor.statusId).toBe(BOOST_WRAPPER_ID);
    expect(String(Number(BOOST_WRAPPER_ID))).not.toBe(BOOST_WRAPPER_ID);
    expect(rowTop(host, BOOST_WRAPPER_ID)).toBe(0);
  });
});

describe('restoreTimelineAnchor', () => {
  it('reapplies the same pixel offset after a row above it grows', () => {
    const growing = { value: 100 };
    const host = createTimelineHost({
      kind: 'history',
      origin: 100,
      rows: [
        { statusId: '100', height: () => growing.value },
        { statusId: '90', height: 120 },
        { statusId: '80', height: 120 },
      ],
    });
    host.scroller.scrollTop = 140;
    const captured = captureTimelineAnchor({ scrollHost: host.scrollHost, alignment: 'top' });
    const before = rowTop(host, captured.statusId) - 100;

    expect(captured.statusId).toBe('90');
    expect(before).toBe(-40);
    growing.value = 260;

    const restored = restoreTimelineAnchor({
      scrollHost: host.scrollHost,
      anchor: captured,
      fallback: 'none',
    });

    expect(restored.ok).toBe(true);
    expect(rowTop(host, '90') - 100).toBeCloseTo(before);
    expect(host.scroller.scrollTop).toBe(300);
  });

  it('leaves scroll untouched when the anchored row was removed', () => {
    const host = createTimelineHost({
      kind: 'document',
      origin: 0,
      scrollTop: 180,
      rows: heights(['100', '90', '80']),
    });
    const anchor = {
      version: 1,
      statusId: '90',
      offsetPx: -12,
      alignment: 'top',
      fallbackScrollTop: 0,
    };
    host.list.querySelector('article[data-id="90"]').remove();
    const restored = restoreTimelineAnchor({ scrollHost: host.scrollHost, visibleTop: 0, anchor, fallback: 'none' });

    expect(restored).toEqual({ ok: false, reason: TIMELINE_ANCHOR_REASONS.NOT_FOUND });
    expect(host.scroller.scrollTop).toBe(180);
  });

  it('uses provisional fallback only when the same-mount caller asks for it', () => {
    const history = createTimelineHost({ kind: 'history', origin: 80, scrollTop: 15, rows: heights(['100']) });
    const missing = {
      version: 1,
      statusId: '90',
      offsetPx: 4,
      alignment: 'top',
      fallbackScrollTop: 222,
    };

    expect(restoreTimelineAnchor({ scrollHost: history.scrollHost, anchor: missing }).ok).toBe(false);
    expect(history.scroller.scrollTop).toBe(15);

    const fallback = restoreTimelineAnchor({
      scrollHost: history.scrollHost,
      anchor: missing,
      fallback: 'absolute',
    });

    expect(fallback.usedFallback).toBe(true);
    expect(fallback.ok).toBe(false);
    expect(history.scroller.scrollTop).toBe(222);
  });
});

describe('scheduleTimelineAnchorFrames', () => {
  it('cancels a stale correction after a newer jump or an abort', () => {
    const frames = [];
    const spy = jest.spyOn(window, 'requestAnimationFrame').mockImplementation((callback) => {
      frames.push(callback);
      return frames.length;
    });
    const cancel = jest.spyOn(window, 'cancelAnimationFrame').mockImplementation(() => {});
    const first = jest.fn();
    const second = jest.fn();
    let aborted = false;
    const stopFirst = scheduleTimelineAnchorFrames({ frames: 2, apply: first, shouldAbort: () => aborted });
    const stopSecond = scheduleTimelineAnchorFrames({ frames: 2, apply: second });

    stopFirst();
    aborted = true;
    frames.splice(0, frames.length).forEach(callback => callback(0));
    expect(first).not.toHaveBeenCalled();
    expect(second).toHaveBeenCalledTimes(1);

    frames.splice(0, frames.length).forEach(callback => callback(0));
    expect(second).toHaveBeenCalledTimes(2);
    stopSecond();
    expect(cancel).toHaveBeenCalled();
    spy.mockRestore();
    cancel.mockRestore();
  });
});
