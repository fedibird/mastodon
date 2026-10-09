jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

import { fromJS, List as ImmutableList } from 'immutable';
import settings from '../settings';
import { COLUMN_ADD, COLUMN_REMOVE } from '../../actions/columns';
import { MIXES_REPLACE } from '../../actions/mixes';
import { STORE_HYDRATE } from '../../actions/store';

const mix = (id, title) => fromJS({
  id,
  version: 1,
  title,
  sources: [
    { type: 'home', params: {} },
    { type: 'public', params: {} },
  ],
});

const withColumns = (state, columns) => state.set('columns', fromJS(columns));

describe('mix settings', () => {
  it('starts with an empty definition list and no fetched posts', () => {
    const state = settings(undefined, { type: '@@INIT' });

    expect(state.get('mixes')).toEqual(ImmutableList());
  });

  it('replaces mixes on hydrate instead of merging them by index', () => {
    const previous = settings(undefined, { type: '@@INIT' }).set('mixes', ImmutableList([
      mix('old-a', 'Old A'),
      mix('old-b', 'Old B'),
    ]));
    const state = settings(withColumns(previous, [
      { id: 'MIX', uuid: 'column-old', params: { id: 'old-a' } },
      { id: 'HOME', uuid: 'column-home', params: {} },
    ]), {
      type: STORE_HYDRATE,
      state: fromJS({
        settings: {
          mixes: [mix('new-a', 'New').toJS()],
          columns: [
            { id: 'HOME', uuid: 'column-home', params: {} },
          ],
        },
      }),
    });

    expect(state.get('mixes').map(item => item.get('id')).toArray()).toEqual(['new-a']);
    expect(state.get('mixes').first().get('title')).toBe('New');
    expect(JSON.stringify(state.get('mixes').toJS())).not.toContain('Old B');
    expect(state.get('columns').some(column => column.get('id') === 'MIX' && column.getIn(['params', 'id']) === 'old-a')).toBe(false);
  });

  it('keeps a mix column uuid distinct from the mix uuid and allows two columns', () => {
    let state = withColumns(settings(undefined, { type: '@@INIT' }), []);

    state = settings(state, { type: MIXES_REPLACE, mixes: ImmutableList([mix('mix-fixed-id', 'Desk')]) });
    state = settings(state, { type: COLUMN_ADD, id: 'MIX', params: { id: 'mix-fixed-id' } });
    state = settings(state, { type: COLUMN_ADD, id: 'MIX', params: { id: 'mix-fixed-id' } });

    const columns = state.get('columns').filter(column => column.get('id') === 'MIX');

    expect(columns.size).toBe(2);
    expect(columns.every(column => column.get('uuid') !== 'mix-fixed-id' && column.getIn(['params', 'id']) === 'mix-fixed-id')).toBe(true);
    expect(columns.get(0).get('uuid')).not.toBe(columns.get(1).get('uuid'));

    state = settings(state, { type: COLUMN_REMOVE, uuid: columns.get(0).get('uuid') });

    expect(state.get('columns').filter(column => column.get('id') === 'MIX').size).toBe(1);
    expect(state.getIn(['mixes', 0, 'id'])).toBe('mix-fixed-id');
  });

  it('removes pinned columns when the mix definition is deleted', () => {
    let state = withColumns(settings(undefined, { type: '@@INIT' }), [
      { id: 'MIX', uuid: 'column-1', params: { id: 'mix-1' } },
      { id: 'MIX', uuid: 'column-2', params: { id: 'mix-1' } },
      { id: 'MIX', uuid: 'column-3', params: { id: 'mix-2' } },
      { id: 'HOME', uuid: 'column-home', params: {} },
    ]).set('mixes', ImmutableList([mix('mix-1', 'One'), mix('mix-2', 'Two')]));

    state = settings(state, { type: MIXES_REPLACE, mixes: ImmutableList([mix('mix-2', 'Two')]) });

    expect(state.get('mixes').map(item => item.get('id')).toArray()).toEqual(['mix-2']);
    expect(state.get('columns').map(column => column.get('uuid')).toArray()).toEqual(['column-3', 'column-home']);
    expect(state.get('saved')).toBe(false);
  });
});
