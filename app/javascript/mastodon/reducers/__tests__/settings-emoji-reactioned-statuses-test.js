jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

import { fromJS, List as ImmutableList } from 'immutable';
import settings from '../settings';
import { COLUMN_ADD, COLUMN_PARAMS_CHANGE, COLUMN_REMOVE } from '../../actions/columns';
import { SETTING_CHANGE } from '../../actions/settings';
import { STORE_HYDRATE } from '../../actions/store';
import { pinnedEmojiReactionColumnParams } from '../../actions/emoji_reactions';

describe('emoji reactioned status settings', () => {
  it('starts with an empty emoji filter list', () => {
    const state = settings(undefined, { type: '@@INIT' });

    expect(state.getIn(['emoji_reactioned_statuses', 'emojis'])).toEqual(ImmutableList());
    expect(state.getIn(['emoji_reactioned_statuses', 'other', 'onlyMedia'])).toBe(false);
    expect(state.getIn(['emoji_reactioned_statuses', 'other', 'withoutMedia'])).toBe(false);
  });

  it('keeps saved media filters when older settings have no emoji list', () => {
    const state = settings(undefined, {
      type: STORE_HYDRATE,
      state: fromJS({
        settings: {
          emoji_reactioned_statuses: {
            other: { onlyMedia: true, withoutMedia: false },
          },
        },
      }),
    });

    expect(state.getIn(['emoji_reactioned_statuses', 'emojis'])).toEqual(ImmutableList());
    expect(state.getIn(['emoji_reactioned_statuses', 'other', 'onlyMedia'])).toBe(true);
  });

  it('copies the current emoji filter into a pinned column and keeps columns independent', () => {
    let state = settings(undefined, { type: '@@INIT' }).set('columns', ImmutableList());
    const pinned = pinnedEmojiReactionColumnParams({
      emojis: fromJS(['achievement@example.com', '🎉']),
      onlyMedia: false,
      withoutMedia: true,
    });

    state = settings(state, { type: COLUMN_ADD, id: 'EMOJI_REACTIONS', params: pinned });
    state = settings(state, {
      type: COLUMN_ADD,
      id: 'EMOJI_REACTIONS',
      params: pinnedEmojiReactionColumnParams({ emojis: ['👍'], onlyMedia: true, withoutMedia: false }),
    });

    const columns = state.get('columns').filter(column => column.get('id') === 'EMOJI_REACTIONS');
    const first = columns.get(0);
    const second = columns.get(1);

    expect(first.getIn(['params', 'emojis']).toJS()).toEqual(['achievement@example.com', '🎉']);
    expect(first.getIn(['params', 'other', 'withoutMedia'])).toBe(true);
    expect(second.getIn(['params', 'emojis']).toJS()).toEqual(['👍']);

    state = settings(state, {
      type: COLUMN_PARAMS_CHANGE,
      uuid: second.get('uuid'),
      path: ['emojis'],
      value: fromJS(['❤️']),
    });

    expect(state.get('columns').find(column => column.get('uuid') === first.get('uuid')).getIn(['params', 'emojis']).toJS()).toEqual(['achievement@example.com', '🎉']);
    expect(state.get('columns').find(column => column.get('uuid') === second.get('uuid')).getIn(['params', 'emojis']).toJS()).toEqual(['❤️']);
    expect(state.getIn(['emoji_reactioned_statuses', 'emojis'])).toEqual(ImmutableList());

    state = settings(state, { type: COLUMN_REMOVE, uuid: first.get('uuid') });
    expect(state.get('columns').filter(column => column.get('id') === 'EMOJI_REACTIONS').size).toBe(1);
  });

  it('stores a default-page emoji filter without changing a pinned column', () => {
    let state = settings(undefined, { type: '@@INIT' }).set('columns', ImmutableList());

    state = settings(state, {
      type: COLUMN_ADD,
      id: 'EMOJI_REACTIONS',
      params: pinnedEmojiReactionColumnParams({ emojis: ['👍'] }),
    });

    const uuid = state.get('columns').find(column => column.get('id') === 'EMOJI_REACTIONS').get('uuid');

    state = settings(state, {
      type: SETTING_CHANGE,
      path: ['emoji_reactioned_statuses', 'emojis'],
      value: ImmutableList(['🎉', '👏']),
    });

    expect(state.getIn(['emoji_reactioned_statuses', 'emojis']).toJS()).toEqual(['🎉', '👏']);
    expect(state.get('columns').find(column => column.get('uuid') === uuid).getIn(['params', 'emojis']).toJS()).toEqual(['👍']);
  });
});
