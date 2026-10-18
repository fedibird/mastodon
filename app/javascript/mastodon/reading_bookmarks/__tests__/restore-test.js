import { bookmarkSeekQuery, runBookmarkRestore, scrollRestoreDecision } from '../restore';

const home = {
  source: 'home',
  path: '/api/v1/timelines/home',
  params: {},
};

const bookmark = {
  id: '4',
  name: 'Morning',
  source: 'home',
  sourceTimelineId: 'home',
  context: {},
  anchor: {
    version: 1,
    statusId: '80',
    displayRowId: 'f-80',
    offsetPx: 14,
    alignment: 'center',
  },
  availability: { source: 'available', anchor: 'visible', membership: 'unchecked' },
  lockVersion: 1,
};

const member = {
  ok: true,
  body: { outcome: 'complete', results: [{ id: '80', outcome: 'member' }] },
};

const reading = {
  version: 1,
  statusId: '100',
  displayRowId: '100',
  offsetPx: 4,
  alignment: 'top',
};

const snapshot = { items: ['100'], windowState: { revision: 1 } };

const harness = (overrides = {}) => {
  const calls = {
    membership: jest.fn(() => Promise.resolve(member)),
    seek: jest.fn(() => Promise.resolve({
      result: {
        outcome: 'resolved',
        anchorId: '80',
        precision: 'exact',
        scroll: { sessionId: 'seek-1' },
      },
      snapshot,
    })),
    rollback: jest.fn(),
    arm: jest.fn(),
    clear: jest.fn(),
  };
  let current = true;
  const run = runBookmarkRestore({
    bookmark,
    contract: home,
    isCurrent: () => current,
    resumeBlocked: false,
    surfaceArmed: false,
    checkMembership: calls.membership,
    seek: calls.seek,
    markScroll: jest.fn(),
    waitForScroll: () => Promise.resolve({ scrollStatus: 'loaded', reason: 'loaded' }),
    rollback: calls.rollback,
    captureReading: () => reading,
    armAnchor: calls.arm,
    clearAnchor: calls.clear,
    ...overrides,
  });

  return {
    calls,
    run,
    setCurrent (value) {
      current = value;
    },
  };
};

describe('reading bookmark restore', () => {
  it('seeks the saved status only after a fresh member check and commits on scroll settle', async () => {
    const { calls, run } = harness();
    const result = await run;

    expect(calls.membership).toHaveBeenCalledWith('80');
    expect(calls.seek).toHaveBeenCalledTimes(1);
    const query = calls.seek.mock.calls[0][0];

    expect(query.kind).toBe('status');
    expect(query.target).toEqual({ id: '80' });
    expect(query.target.q).toBeUndefined();
    expect(JSON.stringify(query)).not.toContain('Morning');
    expect(calls.arm).toHaveBeenCalledWith(bookmark.anchor);
    expect(result).toEqual({ ok: true, moved: true, rollback: false, place: 'exact', reason: 'loaded' });
    expect(calls.rollback).not.toHaveBeenCalled();
  });

  it('keeps redis unknown uncertain and does not seek', async () => {
    const { calls, run } = harness({
      checkMembership: jest.fn(() => Promise.resolve({
        ok: true,
        body: {
          outcome: 'partial',
          results: [{ id: '80', outcome: 'unknown', reason: 'outside_retained_range' }],
        },
      })),
    });
    const result = await run;

    expect(result.place).toBe('uncertain');
    expect(result.rollback).toBe(false);
    expect(calls.seek).not.toHaveBeenCalled();
  });

  it('does not move a different source, a deleted source, or an in-flight resume', async () => {
    const other = harness({
      bookmark: { ...bookmark, source: 'list', sourceTimelineId: 'list:4', context: { id: '4' } },
    });
    const missing = harness({
      bookmark: {
        ...bookmark,
        availability: { source: 'not_accessible', membership: 'member' },
        sourceLabel: 'Hidden',
      },
    });
    const resume = harness({ resumeBlocked: true });

    expect((await other.run).guided).toBe(true);
    expect((await missing.run).reason).toBe('not_accessible');
    expect((await resume.run).reason).toBe('resume_protected');
    expect(other.calls.membership).not.toHaveBeenCalled();
    expect(missing.calls.membership).not.toHaveBeenCalled();
    expect(resume.calls.membership).not.toHaveBeenCalled();
    expect(other.calls.seek).not.toHaveBeenCalled();
  });

  it('rolls the window and the previous reading anchor back when the row does not settle', async () => {
    const { calls, run } = harness({
      waitForScroll: () => Promise.resolve({ scrollStatus: 'filtered', reason: 'filtered' }),
    });
    const result = await run;

    expect(result.rollback).toBe(true);
    expect(result.place).toBe('unavailable');
    expect(calls.rollback).toHaveBeenCalledWith(expect.objectContaining({
      snapshot,
      sessionId: 'seek-1',
      reason: 'filtered',
      reading,
    }));
  });

  it('does not roll back when the reader scrolls, and ignores a stale generation', async () => {
    const scrolled = harness({
      waitForScroll: () => Promise.resolve({ scrollStatus: 'user_scroll', reason: 'user_scroll' }),
    });
    const stale = harness();

    stale.setCurrent(false);

    expect((await scrolled.run).place).toBe('user_scroll');
    expect(scrolled.calls.rollback).not.toHaveBeenCalled();
    expect((await stale.run).place).toBe('stale');
    expect(stale.calls.seek).not.toHaveBeenCalled();
    expect(stale.calls.rollback).not.toHaveBeenCalled();
  });

  it('treats a resolved neighbor as nearby and a retained-range miss as uncertain', async () => {
    const nearby = await harness({
      seek: jest.fn(() => Promise.resolve({
        result: {
          outcome: 'resolved',
          anchorId: '70',
          precision: 'nearest-before',
          scroll: { sessionId: 'seek-2' },
        },
        snapshot,
      })),
    }).run;
    const retained = await harness({
      seek: jest.fn(() => Promise.resolve({
        result: { outcome: 'unavailable', reason: 'outside_retained_range', capability: 'approximate' },
      })),
    }).run;

    expect(nearby.place).toBe('nearby');
    expect(nearby.moved).toBe(true);
    expect(retained).toMatchObject({ place: 'uncertain', reason: 'outside_retained_range', rollback: false });
    expect(scrollRestoreDecision({ place: 'exact', scroll: { scrollStatus: 'not_loaded' } }).rollback).toBe(true);
    expect(bookmarkSeekQuery('80').target.id).toBe('80');
  });
});
