import { fromJS } from 'immutable';

import { FILTERS_IMPORT } from '../../actions/importer';
import filters from '../filters';

describe('filters reducer', () => {
  it('stores imported filters as an ID-keyed map', () => {
    const state = filters(undefined, {
      type: FILTERS_IMPORT,
      filters: [{
        id: 1,
        title: 'spoiler',
        context: ['home'],
        filter_action: 'warn',
        expires_at: null,
      }],
    });

    expect(state.getIn(['1', 'id'])).toEqual('1');
    expect(state.getIn(['1', 'title'])).toEqual('spoiler');
    expect(state.getIn(['1', 'filter_action'])).toEqual('warn');
    expect(state.getIn(['1', 'expires_at'])).toEqual(null);
  });

  it('maps integer streaming filter_action values to warn/hide', () => {
    const state = filters(undefined, {
      type: FILTERS_IMPORT,
      filters: [{
        id: '2',
        title: 'hide me',
        context: ['home'],
        filter_action: 1,
        expires_at: null,
      }],
    });

    expect(state.getIn(['2', 'filter_action'])).toEqual('hide');
  });

  it('parses expires_at into a timestamp', () => {
    const expiresAt = '2024-01-01T00:00:00.000Z';
    const state = filters(undefined, {
      type: FILTERS_IMPORT,
      filters: [{
        id: '3',
        title: 'expired',
        context: ['home'],
        filter_action: 'warn',
        expires_at: expiresAt,
      }],
    });

    expect(state.getIn(['3', 'expires_at'])).toEqual(Date.parse(expiresAt));
  });

  it('ignores incomplete filter objects', () => {
    const initial = fromJS({});
    const state = filters(initial, {
      type: FILTERS_IMPORT,
      filters: [null, {}],
    });

    expect(state).toEqual(initial);
  });
});
