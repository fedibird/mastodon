jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

import { List as ImmutableList, Map as ImmutableMap } from 'immutable';

import {
  budgetChunks,
  nextHistoryCursor,
  parseControl,
  placeReconcileIds,
  planMembership,
  responsePreservesDisplayed,
  spliceHistory,
} from '../reconcile';
import { createExternalFeedSession } from '../session';
import timelines from '../../reducers/timelines';
import mixTimelines from '../../reducers/mix_timelines';
import { TIMELINE_EXTERNAL_RECONCILE } from '../../actions/timelines';
import { MIX_EXTERNAL_RECONCILE } from '../../actions/mix_timelines';

const control = (statusId, revision = '4') => ({
  version: 1,
  reason: 'source_deleted',
  targets: [{ type: 'home' }],
  feed_routes_revision: revision,
  subscription_id: '9',
  status_id: statusId,
  delivery: { route_id: 'should-stay-out' },
});

describe('external feed reconcile', () => {
  it('keeps two statuses that share a feed_routes_revision', () => {
    const first = parseControl(control('10'));
    const second = parseControl(control('11'));

    expect(first.ok).toBe(true);
    expect(second.ok).toBe(true);
    expect(first.statusId).toBe('10');
    expect(second.statusId).toBe('11');
    expect(first.revision).toBe(second.revision);
    expect(JSON.stringify(first)).not.toContain('route_id');

    const session = createExternalFeedSession();
    const token = session.open('home', { targets: [{ type: 'home' }] });
    const shot = session.snapshot('home', token, {});

    session.noteControl(first);
    expect(session.accept(shot).ok).toBe(false);
    const again = session.snapshot('home', token, {});

    session.noteControl(second);
    expect(session.accept(again).ok).toBe(false);
  });

  it('does not remove an id whose stream clock moved after the request, or an unknown row', () => {
    const planned = planMembership({
      rows: [
        { id: '10', outcome: 'not_in_source' },
        { id: '11', outcome: 'not_found' },
        { id: '12', outcome: 'unknown', reason: 'outside_retained_range' },
        { id: '13', outcome: 'member' },
        { id: '14', outcome: 'unknown', reason: 'feed_regenerating' },
      ],
      movedSince: (id) => id === '10',
    });

    expect(planned.removeIds).toEqual(['11']);
    expect(planned.staleIds).toEqual(['10', '14']);
    expect(planned.checkedIds).toEqual(['11', '12', '13']);
    expect(responsePreservesDisplayed(206)).toBe(true);
    expect(responsePreservesDisplayed(429)).toBe(true);
    expect(responsePreservesDisplayed(200)).toBe(false);
  });

  it('keeps a pre-request epoch and rejects only a clock that moves during the request', () => {
    const session = createExternalFeedSession();

    session.noteStatus('90');
    const marker = session.streamMarker();

    expect(session.statusMovedSince('90', marker)).toBe(false);
    expect(session.statusMovedSince('91', marker)).toBe(false);
    session.noteStatus('90');
    expect(session.statusMovedSince('90', marker)).toBe(true);
    expect(session.statusEpoch('90')).toBe(2);
  });

  it('inserts only inside a loaded run and keeps ids above 2^53 as strings', () => {
    const inside = spliceHistory(['9007199254740995', '9007199254740990'], ['9007199254740993', '9007199254740996', '9007199254740989']);
    const gapped = spliceHistory(['100', null, '80'], ['90']);

    expect(inside.inserted).toEqual(['9007199254740993']);
    expect(inside.items).toEqual(['9007199254740995', '9007199254740993', '9007199254740990']);
    expect(gapped.inserted).toEqual([]);
    expect(gapped.items).toEqual(['100', null, '80']);

    expect(placeReconcileIds([], ['90', '100'], { seed: true }).items).toEqual(['100', '90']);
    expect(placeReconcileIds(['50'], ['40', '60']).items).toEqual(['50', '40']);
    expect(placeReconcileIds(['100', null, '80'], ['90']).inserted).toEqual([]);
    expect(placeReconcileIds([null], ['90'], { seed: true }).inserted).toEqual([]);
  });

  it('walks past the first budget instead of repeating the head', () => {
    const ids = Array.from({ length: 401 }, (_value, index) => String(index + 1));
    const checked = new Set();
    const first = budgetChunks(ids.filter(id => !checked.has(id)), 50, 4);

    first.chunks.forEach(chunk => chunk.forEach(id => checked.add(id)));
    const second = budgetChunks(ids.filter(id => !checked.has(id)), 50, 4);

    expect(first.chunks).toHaveLength(4);
    expect(first.remaining).toBe(true);
    expect(second.chunks[0][0]).toBe('201');
    expect(second.remaining).toBe(true);
    second.chunks.forEach(chunk => chunk.forEach(id => checked.add(id)));
    const third = budgetChunks(ids.filter(id => !checked.has(id)), 50, 4);

    expect(third.chunks).toHaveLength(1);
    expect(third.chunks[0]).toEqual(['401']);
    expect(third.remaining).toBe(false);
    expect(nextHistoryCursor({ empty: false, ids: ['100', '80'], oldest: '80' }, [{ id: '70' }], 40).done).toBe(true);
    expect(nextHistoryCursor({ empty: true, ids: [] }, [{ id: '70' }, { id: '60' }], 40).done).toBe(true);
  });

  it('removes and inserts on one timeline without changing unread', () => {
    const state = ImmutableMap({
      home: ImmutableMap({
        unread: 4,
        top: true,
        items: ImmutableList(['40', '30', '10']),
        pendingItems: ImmutableList(['30']),
      }),
      direct: ImmutableMap({
        items: ImmutableList(['10']),
        pendingItems: ImmutableList(),
      }),
    });
    const next = timelines(state, {
      type: TIMELINE_EXTERNAL_RECONCILE,
      timeline: 'home',
      removeIds: ['30'],
      insertIds: ['20'],
    });

    expect(next.getIn(['home', 'items']).toArray()).toEqual(['40', '20', '10']);
    expect(next.getIn(['home', 'pendingItems']).toArray()).toEqual([]);
    expect(next.getIn(['home', 'unread'])).toBe(4);
    expect(next.getIn(['home', 'top'])).toBe(true);
    expect(next.getIn(['direct', 'items']).toArray()).toEqual(['10']);
  });

  it('drops one mix source and leaves the status on the other', () => {
    const state = ImmutableMap({
      col: ImmutableMap({
        sessionId: 's',
        definitionFingerprint: 'fp',
        deletedStatusIds: ImmutableList(),
        pendingStatusIds: ImmutableList(['2']),
        sources: ImmutableMap({
          home: ImmutableMap({ ids: ImmutableList(['1', '2']) }),
          list: ImmutableMap({ ids: ImmutableList(['2', '3']) }),
        }),
      }),
    });
    const next = mixTimelines(state, {
      type: MIX_EXTERNAL_RECONCILE,
      columnKey: 'col',
      sourceKey: 'home',
      sessionId: 's',
      definitionFingerprint: 'fp',
      removeIds: ['2'],
    });

    expect(next.getIn(['col', 'sources', 'home', 'ids']).toArray()).toEqual(['1']);
    expect(next.getIn(['col', 'sources', 'list', 'ids']).toArray()).toEqual(['2', '3']);
    expect(next.getIn(['col', 'pendingStatusIds']).toArray()).toEqual(['2']);
    expect(next.getIn(['col', 'deletedStatusIds']).toArray()).toEqual([]);
  });
});
