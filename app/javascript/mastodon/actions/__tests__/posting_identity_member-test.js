import { Map as ImmutableMap } from 'immutable';
import { applyMiddleware, createStore } from 'redux';
import { combineReducers } from 'redux-immutable';
import thunk from 'redux-thunk';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

jest.mock('../../initial_state', () => ({
  ...jest.requireActual('../../initial_state'),
  me: '42',
  isAdministrator: false,
}));

jest.mock('../../api', () => ({
  __esModule: true,
  default: jest.fn(),
}));

import api from '../../api';
import { changeCompose, submitComposer, uploadToComposer } from '../compose';
import compose from '../../reducers/compose';
import composers from '../../reducers/composers';
import postingIdentities from '../../reducers/posting_identities';
import { selectComposerCanSendAsIdentity } from '../../selectors/posting_identities';

const reducer = combineReducers({
  compose,
  composers,
  postingIdentities,
  posting_contexts: (state = ImmutableMap()) => state,
  timelines: (state = ImmutableMap()) => state,
  statuses: (state = ImmutableMap()) => state,
  accounts: (state = ImmutableMap()) => state,
});

const makeStore = () => createStore(reducer, applyMiddleware(thunk));

const router = {
  location: { pathname: '/home' },
  push: jest.fn(),
  goBack: jest.fn(),
};

describe('non-administrator composer sender', () => {
  beforeEach(() => {
    api.mockReset();
  });

  it('posts and uploads through the current session without a posting identity catalog', async () => {
    const request = jest.fn().mockResolvedValue({
      data: { id: 's1', visibility: 'public', in_reply_to_id: null, scheduled_at: null, tags: [], account: { id: '42' } },
    });
    const post = jest.fn().mockResolvedValue({ status: 200, data: { id: 'm1', type: 'image' } });

    api.mockReturnValue({ request, post });
    const store = makeStore();

    expect(store.getState().getIn(['postingIdentities', 'status'])).toEqual('idle');
    expect(selectComposerCanSendAsIdentity(store.getState(), 'primary')).toEqual(expect.objectContaining({
      canSend: true,
      canUpload: true,
    }));

    store.dispatch(changeCompose('Hello session'));
    await store.dispatch(submitComposer('primary', router));
    await store.dispatch(uploadToComposer('primary', [new File(['x'], 'x.jpg', { type: 'image/jpeg' })]));

    expect(request).toHaveBeenCalledWith(expect.objectContaining({
      url: '/api/v1/statuses',
      method: 'post',
    }));
    expect(request.mock.calls[0][0].data.status).toEqual('Hello session');
    expect(request.mock.calls[0][0].data.posting_identity_id).toEqual('local:42');
    expect(request.mock.calls[0][0].data.account_id).toBeUndefined();
    expect(post.mock.calls[0][0]).toEqual('/api/v2/media');
    expect(post.mock.calls[0][1].get('posting_identity_id')).toEqual('local:42');
    expect(post.mock.calls[0][1].get('account_id')).toBeNull();
  });
});
