import { List as ImmutableList } from 'immutable';

import { capabilityFor, capabilityMatrix, seekKinds, windowedHistoryContracts } from '../capability';
import { CLOSED_SOURCES, SEEK_CAPABILITY, SEEK_KIND } from '../constants';
import { createSeekQuery, seekSourceFromContract, seekSourceKey } from '../query';
import { anchorBeyondSplitBoundary, assembleSeekItems, commitSeekWindow, edgeStatusForSeekPage, planSeekScroll } from '../window';

describe('timeline seek capability', () => {
  it('covers every windowed history contract and leaves closed timelines unsupported', () => {
    const matrix = capabilityMatrix();

    windowedHistoryContracts().forEach(contract => {
      expect(matrix[contract.source]).toBeDefined();
      seekKinds().forEach(kind => {
        expect(capabilityFor(contract.source, kind).level).toBe(matrix[contract.source][kind].level);
      });
    });

    CLOSED_SOURCES.forEach(source => {
      seekKinds().forEach(kind => {
        expect(capabilityFor(source, kind)).toEqual({
          level: SEEK_CAPABILITY.UNSUPPORTED,
          reason: 'source_has_no_windowed_history',
        });
      });
    });

    expect(capabilityFor('personal', SEEK_KIND.ACCOUNT).level).toBe(SEEK_CAPABILITY.UNSUPPORTED);
    expect(capabilityFor('home', SEEK_KIND.STATUS).level).toBe(SEEK_CAPABILITY.APPROXIMATE);
    expect(capabilityFor('public', SEEK_KIND.STATUS).level).toBe(SEEK_CAPABILITY.SUPPORTED);
    expect(capabilityFor('public', SEEK_KIND.DATE).level).toBe(SEEK_CAPABILITY.APPROXIMATE);
  });

  it('reads source identity from the history contract instead of a column id', () => {
    const contract = windowedHistoryContracts().find(item => item.source === 'hashtag');
    const parsed = seekSourceFromContract(contract);

    expect(parsed.source).toBe('hashtag');
    expect(parsed.context.hashtag).toBe('news');
    expect(parsed.context.any).toEqual(['fedibird']);
    expect(parsed.context.column).toBeUndefined();
    expect(seekSourceKey(contract)).toContain('hashtag?');
    expect(seekSourceKey(contract)).not.toContain('secret');
  });
});

describe('timeline seek query', () => {
  it('drops search text and keeps decimal ids as strings', () => {
    const query = createSeekQuery({
      kind: SEEK_KIND.SEARCH_HIT,
      source: 'public',
      target: { id: '9007199254740993', text: 'private query', q: 'other' },
      context: { only_media: false },
    });

    expect(query.version).toBe(1);
    expect(query.target.id).toBe('9007199254740993');
    expect(query.target.rejected).toBe(true);
    expect(query.target.text).toBeUndefined();
    expect(JSON.stringify(query)).not.toContain('private query');
  });
});

describe('timeline seek window', () => {
  it('orders very large ids as decimal strings', () => {
    const items = assembleSeekItems('9007199254740993', ['9007199254740994', '1000'], ['9007199254740992', '999'], null);

    expect(items).toEqual([
      '9007199254740994',
      '9007199254740993',
      '9007199254740992',
      '1000',
      '999',
    ]);
  });

  it('does not keep rows newer than the split boundary', () => {
    const items = assembleSeekItems('50', ['80', '60'], ['40'], '50');

    expect(items).toEqual(['50', '40']);
  });

  it('marks a short redis page unavailable and a short database page exhausted', () => {
    expect(edgeStatusForSeekPage({ ids: ['2'], limit: 40, capability: 'redis', direction: 'older' })).toBe('unavailable');
    expect(edgeStatusForSeekPage({ ids: ['2'], limit: 40, capability: 'database', direction: 'older' })).toBe('exhausted');
    expect(edgeStatusForSeekPage({ ids: [], limit: 40, partial: true, capability: 'redis', direction: 'older' })).toBe('paused');
  });

  it('replaces the neighborhood without moving the boundary or generation', () => {
    const previous = {
      generation: 4,
      revision: 2,
      anchorId: '10',
      anchorResolution: 'exact',
      unbounded: false,
      boundaryId: '90',
      newestId: '30',
      oldestId: '10',
      hasNewer: false,
      hasOlder: true,
      seeking: true,
      newer: { status: 'open', requestId: null, cursor: '30' },
      older: { status: 'open', requestId: null, cursor: '10' },
    };
    const committed = commitSeekWindow(previous, {
      anchorId: '50',
      newerIds: ['70', '60'],
      olderIds: ['40'],
      limit: 40,
      capability: 'database',
    });

    expect(committed.committed).toBe(true);
    expect(committed.items).toEqual(['70', '60', '50', '40']);
    expect(committed.window.generation).toBe(4);
    expect(committed.window.boundaryId).toBe('90');
    expect(committed.window.anchorId).toBe('50');
    expect(committed.window.seeking).toBe(false);
    expect(committed.window.older.status).toBe('exhausted');
    expect(committed.window.newer.status).toBe('exhausted');
  });

  it('refuses to commit an anchor newer than the split boundary', () => {
    const previous = {
      generation: 2,
      revision: 1,
      anchorId: '30',
      boundaryId: '50',
      newestId: '50',
      oldestId: '30',
      hasNewer: false,
      hasOlder: true,
      seeking: true,
      newer: { status: 'open', requestId: null, cursor: '50' },
      older: { status: 'open', requestId: null, cursor: '30' },
    };
    const rejected = commitSeekWindow(previous, {
      anchorId: '80',
      newerIds: ['90'],
      olderIds: ['40'],
      limit: 40,
      capability: 'database',
    });

    expect(anchorBeyondSplitBoundary('80', '50')).toBe(true);
    expect(anchorBeyondSplitBoundary('50', '50')).toBe(false);
    expect(rejected.committed).toBe(false);
    expect(rejected.window).toBe(previous);
  });

  it('does not call a filtered row unloaded, or an unmounted row filtered', () => {
    expect(planSeekScroll({
      anchorId: '50',
      renderedIds: ImmutableList(['70', '40']),
      articlePresent: false,
    })).toEqual({ scroll: false, reason: 'filtered' });

    expect(planSeekScroll({
      anchorId: '50',
      renderedIds: ImmutableList(['70', '50', '40']),
      articlePresent: false,
    })).toEqual({ scroll: false, reason: 'not_loaded' });

    expect(planSeekScroll({
      anchorId: '50',
      renderedIds: ImmutableList(['70', '50']),
    }).scroll).toBe(true);
  });
});

describe('seek source key stability', () => {
  it('changes when source filters change and ignores view ids', () => {
    const left = {
      source: 'public',
      capability: 'database',
      path: '/api/v1/timelines/public',
      params: { remote: true, only_media: false, without_media: false, without_bot: true },
    };
    const right = {
      ...left,
      params: { ...left.params, without_bot: false },
    };

    expect(seekSourceFromContract(left).source).toBe('public');
    expect(seekSourceKey(left)).not.toBe(seekSourceKey(right));
    expect(seekSourceKey(left)).not.toContain('column');
  });
});
