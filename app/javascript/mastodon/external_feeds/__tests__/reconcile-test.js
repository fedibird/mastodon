jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

import { List as ImmutableList, Map as ImmutableMap } from 'immutable';

import {
  parseControl,
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

  it('does not remove an id whose stream epoch moved, or an unknown row', () => {
    const planned = planMembership({
      rows: [
        { id: '10', outcome: 'not_in_source' },
        { id: '11', outcome: 'not_found' },
        { id: '12', outcome: 'unknown' },
        { id: '13', outcome: 'member' },
      ],
      requestedEpochs: { 10: 1, 11: 0, 12: 0, 13: 0 },
      currentEpochs: { 10: 2, 11: 0, 12: 0, 13: 0 },
    });

    expect(planned.removeIds).toEqual(['11']);
    expect(planned.staleIds).toEqual(['10']);
    expect(responsePreservesDisplayed(206)).toBe(true);
    expect(responsePreservesDisplayed(429)).toBe(true);
    expect(responsePreservesDisplayed(200)).toBe(false);
  });

  it('inserts only inside a loaded run and keeps ids above 2^53 as strings', () => {
    const inside = spliceHistory(['9007199254740995', '9007199254740990'], ['9007199254740993', '9007199254740996', '9007199254740989']);
    const gapped = spliceHistory(['100', null, '80'], ['90']);

    expect(inside.inserted).toEqual(['9007199254740993']);
    expect(inside.items).toEqual(['9007199254740995', '9007199254740993', '9007199254740990']);
    expect(gapped.inserted).toEqual([]);
    expect(gapped.items).toEqual(['100', null, '80']);
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
