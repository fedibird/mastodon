import { List as ImmutableList, fromJS } from 'immutable';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

import composer from '../composer';

const attachments = (...ids) => ImmutableList(ids.map((id, order) => fromJS({ id, order, description: `${id} alt` })));

describe('composer media order', () => {
  it('moves an attachment to an arbitrary index and keeps alt text with its id', () => {
    const state = composer(undefined, { type: '@@init' }).set('media_attachments', attachments('a', 'b', 'c', 'd'));
    const moved = composer(state, { type: 'COMPOSE_MEDIA_ORDER_CHANGE', id: 'a', toIndex: 2 });

    expect(moved.get('media_attachments').map(item => item.get('id')).toJS()).toEqual(['b', 'c', 'a', 'd']);
    expect(moved.get('media_attachments').find(item => item.get('id') === 'a').get('description')).toEqual('a alt');
    expect(moved.get('media_attachments').map(item => item.get('order')).toJS()).toEqual([0, 1, 2, 3]);

    const restored = composer(moved, { type: 'COMPOSE_MEDIA_ORDER_CHANGE', id: 'a', toIndex: 0 });

    expect(restored.get('media_attachments').map(item => item.get('id')).toJS()).toEqual(['a', 'b', 'c', 'd']);
  });
});
