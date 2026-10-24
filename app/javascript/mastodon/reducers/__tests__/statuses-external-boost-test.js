import { fromJS } from 'immutable';

jest.mock('../../actions/statuses', () => ({
  STATUS_MUTE_SUCCESS: 'STATUS_MUTE_SUCCESS',
  STATUS_UNMUTE_SUCCESS: 'STATUS_UNMUTE_SUCCESS',
  STATUS_REVEAL: 'STATUS_REVEAL',
  STATUS_HIDE: 'STATUS_HIDE',
  STATUS_COLLAPSE: 'STATUS_COLLAPSE',
  STATUS_TRANSLATE_SUCCESS: 'STATUS_TRANSLATE_SUCCESS',
  STATUS_TRANSLATE_UNDO: 'STATUS_TRANSLATE_UNDO',
  STATUS_TRANSLATE_REQUEST: 'STATUS_TRANSLATE_REQUEST',
  STATUS_TRANSLATE_FAIL: 'STATUS_TRANSLATE_FAIL',
  STATUS_TRANSLATE_SET_MODE: 'STATUS_TRANSLATE_SET_MODE',
  STATUS_TRANSLATION_ASSUMPTION: 'STATUS_TRANSLATION_ASSUMPTION',
  STATUS_TRANSLATION_TARGET: 'STATUS_TRANSLATION_TARGET',
}));
jest.mock('../../api', () => ({ __esModule: true, default: jest.fn(), getLinks: () => ({ refs: [] }) }));

import { EXTERNAL_LINK_BOOST_CHANGED } from '../../actions/external_boosts';
import {
  REBLOG_FAIL,
  REBLOG_REQUEST,
  UNREBLOG_FAIL,
  UNREBLOG_REQUEST,
} from '../../actions/interactions';
import { STATUS_IMPORT, STATUSES_IMPORT } from '../../actions/importer';
import statuses from '../statuses';

const HUGE = '9007199254740993';

const projection = (revision, reblogged, extra = {}) => ({
  id: '100',
  content: 'body',
  reblogged,
  fedibird_external: { protocol: 'rss', link_boost_revision: revision, source_title: 'Feed' },
  ...extra,
});

const importOne = (state, status) => statuses(state, { type: STATUS_IMPORT, status });
const event = (revision, reblogged, statusId = '100') => ({ type: EXTERNAL_LINK_BOOST_CHANGED, statusId, revision, reblogged });
const pair = (state, id = '100') => [state.getIn([id, 'reblogged']), state.getIn([id, 'fedibird_external', 'link_boost_revision'])];

describe('statuses reducer: share state of a projection', () => {
  it('does not let an older payload roll back a newer pair, and imports its other fields', () => {
    let state = importOne(undefined, projection('3', true));

    state = importOne(state, projection('2', false, { content: 'edited body' }));

    expect(pair(state)).toEqual([true, '3']);
    expect(state.getIn(['100', 'content'])).toBe('edited body');
    expect(state.getIn(['100', 'fedibird_external', 'source_title'])).toBe('Feed');
  });

  it('takes a newer payload and treats the same revision as a no-op', () => {
    let state = importOne(undefined, projection('1', true));

    state = importOne(state, projection('2', false));
    expect(pair(state)).toEqual([false, '2']);
    const again = importOne(state, projection('2', false));

    expect(again.getIn(['100', 'reblogged'])).toBe(false);
    expect(pair(again)).toEqual([false, '2']);
  });

  it('restores true, false, true as revisions 1, 2, 3 in every order of arrival', () => {
    const payloads = { 1: projection('1', true), 2: projection('2', false), 3: projection('3', true) };
    const orders = [[1, 2, 3], [3, 2, 1], [2, 3, 1], [2, 1, 3], [1, 3, 2], [3, 1, 2]];

    orders.forEach(order => {
      const viaRest = order.reduce((state, number) => importOne(state, payloads[number]), undefined);
      const viaStream = order.reduce((state, number) => {
        const next = importOne(state, payloads[1]);

        return statuses(next, event(String(number), payloads[number].reblogged));
      }, undefined);

      expect(pair(viaRest)).toEqual([true, '3']);
      expect(pair(viaStream)).toEqual([true, '3']);
    });
  });

  it('orders a stream frame ahead of a delayed REST response and the reverse', () => {
    let state = importOne(undefined, projection('1', true));

    state = statuses(state, event('2', false));
    state = importOne(state, projection('1', true));
    expect(pair(state)).toEqual([false, '2']);

    let other = importOne(undefined, projection('3', true));

    other = statuses(other, event('2', false));
    expect(pair(other)).toEqual([true, '3']);
  });

  it('applies the same protection through STATUSES_IMPORT', () => {
    let state = importOne(undefined, projection('4', false));

    state = statuses(state, { type: STATUSES_IMPORT, statuses: [projection('3', true), { id: '7', reblogged: true }] });

    expect(pair(state)).toEqual([false, '4']);
    expect(state.getIn(['7', 'reblogged'])).toBe(true);
  });

  it('compares revisions as decimal strings past 2^53', () => {
    let state = importOne(undefined, projection('9007199254740994', true));

    state = importOne(state, projection(HUGE, false));
    expect(pair(state)).toEqual([true, '9007199254740994']);
    state = statuses(state, event('9007199254740995', false));
    expect(pair(state)).toEqual([false, '9007199254740995']);
    state = statuses(state, event('9007199254740994', true));
    expect(pair(state)).toEqual([false, '9007199254740995']);
    state = importOne(state, projection('10000000000000000000', true));
    expect(pair(state)).toEqual([true, '10000000000000000000']);
  });

  it('ignores a stream event for a status that is not held, and does not store it', () => {
    const state = statuses(undefined, event('5', true, '999'));

    expect(state.size).toBe(0);
  });

  it('does not touch a status with no revision, and keeps the old full import', () => {
    const plain = { id: '8', content: 'a', reblogged: true, reblogs_count: 2 };
    let state = importOne(undefined, plain);

    state = importOne(state, { id: '8', content: 'b', reblogged: false, reblogs_count: 1 });
    expect(state.get('8').toJS()).toEqual({ id: '8', content: 'b', reblogged: false, reblogs_count: 1 });

    const held = importOne(undefined, { id: '9', reblogged: true });
    const withRevision = importOne(held, projection('1', false, { id: '9' }));

    expect(pair(withRevision, '9')).toEqual([false, '1']);
  });

  it('does not take a revision from a payload that has none', () => {
    let state = importOne(undefined, projection('2', true));

    state = importOne(state, { id: '100', content: 'x', reblogged: false });
    expect(state.getIn(['100', 'reblogged'])).toBe(false);
  });

  describe('optimistic boost and its rollback', () => {
    const request = type => ({ type, status: fromJS({ id: '100' }) });

    it('keeps the click against an equal-revision stale read, then yields to a newer revision', () => {
      let state = importOne(undefined, projection('2', false));

      state = statuses(state, request(REBLOG_REQUEST));
      expect(state.getIn(['100', 'reblogged'])).toBe(true);
      state = importOne(state, projection('2', false));
      expect(pair(state)).toEqual([true, '2']);
      state = importOne(state, projection('3', true));
      expect(pair(state)).toEqual([true, '3']);
      expect(state.getIn(['100', 'link_boost_optimistic'])).toBeUndefined();
    });

    it('rolls a failed boost back only while no newer revision has been applied', () => {
      let state = importOne(undefined, projection('2', false));

      state = statuses(state, request(REBLOG_REQUEST));
      state = statuses(state, request(REBLOG_FAIL));
      expect(pair(state)).toEqual([false, '2']);
      expect(state.getIn(['100', 'link_boost_optimistic'])).toBeUndefined();

      state = statuses(state, request(REBLOG_REQUEST));
      state = statuses(state, event('3', true));
      state = statuses(state, request(REBLOG_FAIL));
      expect(pair(state)).toEqual([true, '3']);
    });

    it('does the same for an undo that fails after another tab changed the state', () => {
      let state = importOne(undefined, projection('1', true));

      state = statuses(state, request(UNREBLOG_REQUEST));
      expect(state.getIn(['100', 'reblogged'])).toBe(false);
      state = statuses(state, request(UNREBLOG_FAIL));
      expect(pair(state)).toEqual([true, '1']);

      state = statuses(state, request(UNREBLOG_REQUEST));
      state = statuses(state, event('2', false));
      state = statuses(state, event('3', true));
      state = statuses(state, request(UNREBLOG_FAIL));
      expect(pair(state)).toEqual([true, '3']);
    });

    it('does not let a late rollback undo a state applied after a retry', () => {
      let state = importOne(undefined, projection('1', true));

      state = statuses(state, request(UNREBLOG_REQUEST));
      state = importOne(state, projection('2', false));
      state = statuses(state, request(UNREBLOG_FAIL));
      expect(pair(state)).toEqual([false, '2']);
    });

    it('leaves ordinary statuses on the previous behavior', () => {
      let state = importOne(undefined, { id: '8', reblogged: false });

      state = statuses(state, { type: REBLOG_REQUEST, status: fromJS({ id: '8' }) });
      expect(state.getIn(['8', 'reblogged'])).toBe(true);
      expect(state.getIn(['8', 'link_boost_optimistic'])).toBeUndefined();
      state = statuses(state, { type: REBLOG_FAIL, status: fromJS({ id: '8' }) });
      expect(state.getIn(['8', 'reblogged'])).toBe(false);
      state = statuses(state, { type: UNREBLOG_FAIL, status: fromJS({ id: '8' }) });
      expect(state.getIn(['8', 'reblogged'])).toBe(true);
      expect(statuses(undefined, { type: UNREBLOG_FAIL, status: fromJS({ id: '404' }) }).size).toBe(0);
    });
  });

  it('keeps the old import cost for statuses without a revision', () => {
    const list = Array.from({ length: 2000 }, (_value, index) => ({ id: String(index + 1), content: 'x', reblogged: index % 2 === 0 }));
    let state = statuses(undefined, { type: STATUSES_IMPORT, statuses: list });
    const started = Date.now();

    state = statuses(state, { type: STATUSES_IMPORT, statuses: list });

    expect(Date.now() - started).toBeLessThan(2000);
    expect(state.size).toBe(2000);
  });
});
