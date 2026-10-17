import { historySourceIdentity, historyViewIdentity } from '../identity';
import { createPositionRegistry } from '../registry';
import { homeHistoryContract } from '../../windowed_history/sources';

const anchor = (statusId, offsetPx = 8) => ({
  version: 1,
  statusId,
  displayRowId: statusId,
  offsetPx,
  alignment: 'top',
  capturedAt: '2026-10-17T00:00:00.000Z',
});

const home = homeHistoryContract(['public']);

describe('timeline position registry', () => {
  const build = (options) => {
    let clock = 0;
    const registry = createPositionRegistry({ now: () => clock, ttlMs: 1000, maxEntries: 2, ...options });

    return {
      registry,
      advance: (ms) => {
        clock += ms;
      },
    };
  };

  const viewFor = (columnId, locationKey = 'route-a') => historyViewIdentity({
    columnId,
    sourceTimelineId: 'home',
    locationKey,
  });

  it('keeps two columns of one source independent and ignores a new location key', () => {
    const { registry } = build();
    const source = historySourceIdentity('home', home);
    const left = viewFor('column-a', 'route-a');
    const right = viewFor('column-b', 'route-a');

    registry.record({
      accountId: '1',
      source,
      view: left,
      anchor: anchor('100'),
      routeEntryKey: 'route-a',
      sync: true,
      at: 1,
    });
    registry.record({
      accountId: '1',
      source,
      view: right,
      anchor: anchor('200'),
      routeEntryKey: 'route-a',
      sync: true,
      at: 2,
    });

    const revisited = historyViewIdentity({
      columnId: 'column-a',
      sourceTimelineId: 'home',
      locationKey: 'route-b',
    });

    expect(registry.find('1', source, revisited, 3).position.anchor.statusId).toBe('100');
    expect(registry.find('1', source, right, 3).position.anchor.statusId).toBe('200');
    expect(registry.find('1', historySourceIdentity('home', homeHistoryContract(['private'])), left, 3)).toBeNull();
  });

  it('drops another account and does not keep status text or tokens', () => {
    const { registry } = build();
    const source = historySourceIdentity('list:7', { source: 'list', path: '/api/v1/timelines/list/7', params: {} });
    const view = historyViewIdentity({ columnId: 'column-a', sourceTimelineId: 'list:7' });
    const secret = 'session-token-should-not-stick';

    const result = registry.record({
      accountId: '1',
      source,
      view,
      anchor: {
        ...anchor('55'),
        text: 'hello from the post',
        token: secret,
      },
      sync: true,
      at: 1,
    });

    expect(result.ok).toBe(true);
    expect(JSON.stringify(result.record)).not.toContain('hello from the post');
    expect(JSON.stringify(result.record)).not.toContain(secret);
    expect(registry.find('2', source, view, 2)).toBeNull();
    expect(registry.noteAccount('2')).toBe('2');
    expect(registry.find('1', source, view, 3)).toBeNull();
  });

  it('caps entries, expires them, and refuses capture while a restore holds the row', () => {
    const { registry, advance } = build();
    const source = historySourceIdentity('home', home);
    const first = viewFor('column-a');
    const second = viewFor('column-b');
    const third = viewFor('column-c');

    registry.record({ accountId: '1', source, view: first, anchor: anchor('1'), sync: true, at: 10 });
    registry.record({ accountId: '1', source, view: second, anchor: anchor('2'), sync: true, at: 20 });
    registry.record({ accountId: '1', source, view: third, anchor: anchor('3'), sync: true, at: 30 });

    expect(registry.size()).toBe(2);
    expect(registry.find('1', source, first, 30)).toBeNull();

    registry.hold('1', source, third, 'resume-1');

    const blocked = registry.record({
      accountId: '1',
      source,
      view: third,
      anchor: anchor('9'),
      sync: true,
      at: 40,
    });

    expect(blocked.reason).toBe('restore_hold');
    expect(registry.find('1', source, third, 40).position.anchor.statusId).toBe('3');
    expect(registry.releaseHold('1', source, third, 'resume-1').ok).toBe(true);

    advance(2000);
    expect(registry.find('1', source, third)).toBeNull();
  });
});
