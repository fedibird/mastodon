import { fromJS, Map as ImmutableMap, List as ImmutableList, Set as ImmutableSet } from 'immutable';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

jest.mock('../../api', () => ({
  __esModule: true,
  default: jest.fn(),
}));

jest.mock('../importer', () => ({
  importFetchedStatus: jest.fn(status => ({ type: 'STATUS_IMPORT', status })),
  importFetchedStatuses: jest.fn(() => ({ type: 'STATUSES_IMPORT' })),
  importFetchedAccount: jest.fn(),
}));

jest.mock('../accounts', () => ({
  fetchRelationshipsFromStatus: jest.fn(() => ({ type: 'RELATIONSHIPS_FETCH' })),
  fetchRelationshipsFromStatuses: jest.fn(() => ({ type: 'RELATIONSHIPS_FETCH' })),
}));

jest.mock('../timelines', () => ({
  deleteFromTimelines: jest.fn(() => ({ type: 'TIMELINE_DELETE' })),
  expireFromTimelines: jest.fn(),
}));

jest.mock('../compose', () => ({
  ensureComposeIsVisible: jest.fn(),
  getContextReference: jest.fn(),
  setComposeToStatus: jest.fn((status, text, spoilerText) => ({
    type: 'COMPOSE_SET_STATUS',
    status,
    text,
    spoiler_text: spoilerText,
  })),
}));

jest.mock('../modal', () => ({
  openModal: (type, props) => ({ type: 'MODAL_OPEN', modalType: type, modalProps: props }),
}));

import api from '../../api';
import { ensureComposeIsVisible, setComposeToStatus } from '../compose';
import { editStatus, requestEditStatus } from '../statuses';

const dispatchThunk = (thunk, state) => {
  const actions = [];
  const dispatch = (action) => {
    if (typeof action === 'function') {
      return action(dispatch, () => state);
    }

    actions.push(action);
    return action;
  };

  return Promise.resolve(thunk(dispatch, () => state)).then(() => actions);
};

const compose = (overrides = {}) => ImmutableMap({
  text: '',
  media_attachments: ImmutableList(),
  poll: null,
  quote_from: null,
  references: ImmutableSet(),
  scheduled: null,
  id: null,
}).merge(overrides);

describe('editStatus', () => {
  const state = fromJS({
    statuses: {
      s1: {
        id: 's1',
        poll: 'p1',
        content: '<p>html body</p>',
        spoiler_text: '<p>html spoiler</p>',
      },
    },
    polls: {
      p1: {
        id: 'p1',
        options: [{ title: 'Yes' }],
        multiple: false,
      },
    },
    compose: compose(),
  });

  beforeEach(() => {
    api.mockReset();
    ensureComposeIsVisible.mockClear();
    setComposeToStatus.mockClear();
  });

  it('loads raw source text into compose after GET /source', async () => {
    api.mockReturnValue({
      get: jest.fn().mockResolvedValue({ data: { text: 'raw body', spoiler_text: 'raw spoiler' } }),
    });

    const actions = await dispatchThunk(editStatus('s1', { push: jest.fn() }), state);

    expect(api().get).toHaveBeenCalledWith('/api/v1/statuses/s1/source');
    expect(actions.map(action => action.type)).toEqual([
      'STATUS_FETCH_SOURCE_REQUEST',
      'STATUS_FETCH_SOURCE_SUCCESS',
      'COMPOSE_SET_STATUS',
    ]);
    expect(setComposeToStatus).toHaveBeenCalledWith(
      expect.objectContaining({ get: expect.any(Function) }),
      'raw body',
      'raw spoiler',
    );
    const statusArg = setComposeToStatus.mock.calls[0][0];
    expect(statusArg.getIn(['poll', 'options', 0, 'title'])).toEqual('Yes');
    expect(statusArg.get('content')).toEqual('<p>html body</p>');
    expect(actions[2].text).toEqual('raw body');
    expect(ensureComposeIsVisible).toHaveBeenCalled();
  });

  it('does not enter editing state when source fetch fails', async () => {
    const error = { response: { status: 500, statusText: 'nope', data: { error: 'nope' } } };
    api.mockReturnValue({
      get: jest.fn().mockRejectedValue(error),
    });

    const actions = await dispatchThunk(editStatus('s1', { push: jest.fn() }), state);

    expect(actions.map(action => action.type)).toEqual([
      'STATUS_FETCH_SOURCE_REQUEST',
      'STATUS_FETCH_SOURCE_FAIL',
    ]);
    expect(actions[1].error).toBe(error);
    expect(setComposeToStatus).not.toHaveBeenCalled();
    expect(ensureComposeIsVisible).not.toHaveBeenCalled();
  });

  it('asks before overwriting an existing compose draft', async () => {
    api.mockReturnValue({ get: jest.fn() });
    const draftState = state.set('compose', compose({ text: 'draft' }));
    const intl = { formatMessage: ({ defaultMessage }) => defaultMessage };
    const actions = await dispatchThunk(requestEditStatus(fromJS({ id: 's1' }), { push: jest.fn() }, intl), draftState);

    expect(api).not.toHaveBeenCalled();
    expect(actions[0].type).toEqual('MODAL_OPEN');
    expect(actions[0].modalType).toEqual('CONFIRM');
  });
});
