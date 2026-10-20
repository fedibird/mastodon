import { fromJS, List as ImmutableList, Map as ImmutableMap, Set as ImmutableSet } from 'immutable';
import { applyMiddleware, createStore } from 'redux';
import thunk from 'redux-thunk';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

jest.mock('../../api', () => ({
  __esModule: true,
  default: jest.fn(),
}));

jest.mock('../importer', () => ({
  importFetchedAccounts: jest.fn(),
  importFetchedStatus: jest.fn(status => ({ type: 'STATUS_IMPORT', status })),
}));

jest.mock('../timelines', () => ({
  updateTimeline: jest.fn((timelineId, status) => ({ type: 'TIMELINE_UPDATE', timelineId, status })),
}));

jest.mock('../scheduled_statuses', () => ({
  deleteScheduledStatus: jest.fn(id => ({ type: 'SCHEDULED_STATUS_DELETE', id })),
}));

jest.mock('../../selectors', () => ({
  getHomeVisibilities: () => ['public'],
  getLimitedVisibilities: () => ['private'],
}));

jest.mock('../alerts', () => ({
  showAlert: jest.fn((title, message) => ({ type: 'ALERT_SHOW', title, message })),
  showAlertForError: jest.fn(error => ({ type: 'ALERT_FAIL', error })),
}));

jest.mock('../modal', () => ({
  openModal: jest.fn((type, props) => ({ type: 'MODAL_OPEN', modalType: type, modalProps: props })),
}));

jest.mock('../../initial_state', () => ({
  postReferenceModal: true,
  missingAltTextModal: true,
  enableFederatedTimeline: true,
  allowPollImage: false,
  maxAttachments: 4,
  disablePost: false,
}));

import api from '../../api';
import { importFetchedStatus } from '../importer';
import { updateTimeline } from '../timelines';
import { openModal } from '../modal';
import { COMPOSE_CHANGE, COMPOSE_POLL_ADD, COMPOSE_POLL_OPTION_CHANGE, COMPOSE_SPOILER_TEXT_CHANGE, COMPOSE_SPOILERNESS_CHANGE, COMPOSE_SUBMIT_REQUEST, COMPOSE_SUBMIT_SUCCESS, changeUploadCompose, submitCompose, submitComposeWithCheck } from '../compose';
import { applyComposerPostingContext } from '../composer';
import { USER_POSTING_STYLES_FETCH_SUCCESS, commitUserPostingStyle, setPostingStyleUsage } from '../user_posting_styles';
import { groupPostingContext } from '../../posting_context/fixtures/group_context_fixture';
import { mitraGroupPostingContext } from '../../posting_context/fixtures/mitra_group_context_fixture';
import composeReducer from '../../reducers/compose';
import composerReducer, { initialState as initialComposerState } from '../../reducers/composer';
import userPostingStyles from '../../reducers/user_posting_styles';
import { PRIMARY_COMPOSER_ID } from '../../utils/composer';

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

const media = ImmutableList([
  fromJS({ id: 'm1', description: 'alt one', meta: { focus: { x: 0.5, y: -0.25 } } }),
  fromJS({ id: 'm2', description: 'alt two', meta: {} }),
]);

const composeState = (overrides = {}) => fromJS({
  compose: {
    id: null,
    text: 'hello',
    spoiler: true,
    spoiler_text: 'cw',
    sensitive: true,
    language: 'ja',
    privacy: 'private',
    senderIdentity: { id: null, status: 'ready' },
    circle_id: 'circle-1',
    in_reply_to: 'reply-1',
    quote_from: 'quote-1',
    searchability: 'public',
    scheduled: null,
    expires: null,
    expires_action: 'mark',
    scheduled_status_id: null,
    idempotencyKey: 'idem-1',
    tagHistory: [],
  },
  timelines: {
    home: {
      items: ['old'],
      online: true,
    },
  },
}).setIn(['compose', 'media_attachments'], media)
  .setIn(['compose', 'references'], ImmutableSet(['ref-1']))
  .setIn(['compose', 'poll'], ImmutableMap({
    options: ImmutableList(['Yes', 'No']),
    multiple: false,
    expires_in: 3600,
  }))
  .mergeIn(['compose'], overrides.compose || {});

const statusResponse = {
  id: 's1',
  visibility: 'public',
  in_reply_to_id: null,
  scheduled_at: null,
  tags: [],
  account: { id: 'a1' },
};

const intl = {
  formatMessage: message => message.defaultMessage || message.id,
};

describe('submitCompose', () => {
  beforeEach(() => {
    api.mockReset();
    importFetchedStatus.mockClear();
    updateTimeline.mockClear();
    openModal.mockClear();
  });

  it.each(['public', 'private', 'direct'])('caps the %s search payload against private visibility', async desired => {
    const request = jest.fn().mockResolvedValue({ data: statusResponse });
    api.mockReturnValue({ request });

    await dispatchThunk(submitCompose({ location: { pathname: '/home' }, push: jest.fn(), goBack: jest.fn() }), composeState({ compose: { privacy: 'private', searchability: desired } }));

    expect(request.mock.calls[0][0].data.visibility).toBe('private');
    expect(request.mock.calls[0][0].data.searchability).toBe(desired === 'direct' ? 'direct' : 'private');
  });

  it('POSTs a new status with the Fedibird payload', async () => {
    const request = jest.fn().mockResolvedValue({ data: statusResponse });
    api.mockReturnValue({ request });

    await dispatchThunk(submitCompose({ location: { pathname: '/home' }, push: jest.fn(), goBack: jest.fn() }), composeState());

    expect(request).toHaveBeenCalledWith(expect.objectContaining({
      url: '/api/v1/statuses',
      method: 'post',
    }));
    const data = request.mock.calls[0][0].data;
    expect(data.visibility).toEqual('private');
    expect(data.circle_id).toEqual('circle-1');
    expect(data.quote_id).toEqual('quote-1');
    expect(data.status_reference_ids.toJS()).toEqual(['ref-1']);
    expect(data.searchability).toEqual('private');
    expect(data.in_reply_to_id).toEqual('reply-1');
    expect(data.language).toEqual('ja');
    expect(updateTimeline).toHaveBeenCalled();
    expect(importFetchedStatus).not.toHaveBeenCalled();
  });

  it('marks a new schedule as schedule and an existing scheduled post as an edit', async () => {
    const request = jest.fn()
      .mockResolvedValueOnce({ data: { ...statusResponse, scheduled_at: '2099-01-01T00:00:00.000Z' } })
      .mockResolvedValueOnce({ data: { ...statusResponse, scheduled_at: '2099-01-01T00:00:00.000Z' } })
      .mockResolvedValueOnce({ data: statusResponse });
    api.mockReturnValue({ request });
    const router = { location: { pathname: '/home' }, push: jest.fn(), goBack: jest.fn() };

    const created = await dispatchThunk(submitCompose(router), composeState({ compose: { scheduled: '2099-01-01 00:00' } }));
    expect(created.find(action => action.type === 'SCHEDULED_STATUS_SUBMIT_SUCCESS').submission.kind).toEqual('schedule');

    const kept = await dispatchThunk(
      submitCompose(router),
      composeState({ compose: { scheduled: '2099-01-01 00:00', scheduled_status_id: 'sched-1' } }),
    );
    expect(kept.find(action => action.type === 'SCHEDULED_STATUS_SUBMIT_SUCCESS').submission.kind).toEqual('edit');

    const immediate = await dispatchThunk(
      submitCompose(router),
      composeState({ compose: { scheduled: null, scheduled_status_id: 'sched-1' } }),
    );
    expect(immediate.find(action => action.type === 'COMPOSE_SUBMIT_SUCCESS').submission.kind).toEqual('edit');
  });

  it('sends the selected language with a scheduled post', async () => {
    const request = jest.fn().mockResolvedValue({ data: { ...statusResponse, scheduled_at: '2099-01-01T00:00:00.000Z' } });
    api.mockReturnValue({ request });

    await dispatchThunk(
      submitCompose({ location: { pathname: '/home' }, push: jest.fn(), goBack: jest.fn() }),
      composeState({ compose: { scheduled: '2099-01-01 00:00', language: 'en' } }),
    );

    const data = request.mock.calls[0][0].data;
    expect(request).toHaveBeenCalledWith(expect.objectContaining({
      url: '/api/v1/statuses',
      method: 'post',
    }));
    expect(data.language).toEqual('en');
    expect(data.scheduled_at).toEqual(expect.any(String));
  });

  it('PUTs an edit with only the update contract and does not insert a timeline duplicate', async () => {
    const request = jest.fn().mockResolvedValue({ data: { ...statusResponse, id: 's9', edited_at: '2026-01-02T00:00:00.000Z' } });
    api.mockReturnValue({ request });

    const actions = await dispatchThunk(
      submitCompose({ location: { pathname: '/home' }, push: jest.fn(), goBack: jest.fn() }),
      composeState({ compose: { id: 's9' } }),
    );

    expect(request).toHaveBeenCalledWith(expect.objectContaining({
      url: '/api/v1/statuses/s9',
      method: 'put',
    }));

    const data = request.mock.calls[0][0].data;
    expect(data).toEqual(expect.objectContaining({
      status: 'hello',
      spoiler_text: 'cw',
      sensitive: true,
      language: 'ja',
      media_ids: ['m1', 'm2'],
      poll: {
        options: ['Yes', 'No'],
        multiple: false,
        expires_in: 3600,
      },
    }));
    expect(data.media_attributes).toEqual([
      { id: 'm1', description: 'alt one', focus: '0.50,-0.25' },
      { id: 'm2', description: 'alt two' },
    ]);
    expect(data).not.toHaveProperty('visibility');
    expect(data).not.toHaveProperty('circle_id');
    expect(data).not.toHaveProperty('quote_id');
    expect(data).not.toHaveProperty('status_reference_ids');
    expect(data).not.toHaveProperty('scheduled_at');
    expect(data).not.toHaveProperty('expires_at');
    expect(data).not.toHaveProperty('searchability');
    expect(data).not.toHaveProperty('in_reply_to_id');
    expect(data).not.toHaveProperty('audience_account_id');
    expect(importFetchedStatus).toHaveBeenCalledWith(expect.objectContaining({ id: 's9' }));
    expect(updateTimeline).not.toHaveBeenCalled();
    expect(actions.map(action => action.type)).toEqual(expect.arrayContaining(['STATUS_IMPORT', 'ALERT_SHOW']));
    expect(actions.map(action => action.type)).not.toEqual(expect.arrayContaining(['TIMELINE_UPDATE']));
  });

  it('keeps attached media description in compose instead of calling the media API', async () => {
    const request = jest.fn();
    const put = jest.fn();
    api.mockReturnValue({ request, put });

    const state = composeState({ compose: { id: 's9' } })
      .setIn(['compose', 'media_attachments'], media.map(item => item.set('unattached', false)));
    const actions = await dispatchThunk(changeUploadCompose('m1', { description: 'ALT-RED-2', focus: '0.10,-0.20' }), state);

    expect(state.getIn(['compose', 'media_attachments', 0, 'unattached'])).toBe(false);
    expect(put).not.toHaveBeenCalled();
    expect(request).not.toHaveBeenCalled();
    const success = actions.find(action => action.type === 'COMPOSE_UPLOAD_UPDATE_SUCCESS');
    expect(success.media.description).toEqual('ALT-RED-2');
    expect(success.media.meta.focus).toEqual({ x: 0.1, y: -0.2 });
    expect(success.attached).toBe(true);
  });

  it('asks to confirm references on a new post and skips that check while editing', async () => {
    const request = jest.fn().mockResolvedValue({ data: { ...statusResponse, id: 's9' } });
    api.mockReturnValue({ request });
    const router = { location: { pathname: '/home' }, push: jest.fn(), goBack: jest.fn() };

    const draftActions = await dispatchThunk(submitComposeWithCheck(router, intl), composeState());

    expect(openModal).toHaveBeenCalledWith('CONFIRM', expect.objectContaining({
      message: 'It contains references, do you want to post it?',
    }));
    expect(request).not.toHaveBeenCalled();
    expect(draftActions.map(action => action.modalType)).toEqual(['CONFIRM']);

    openModal.mockClear();
    const editActions = await dispatchThunk(submitComposeWithCheck(router, intl), composeState({ compose: { id: 's9' } }));

    expect(openModal).not.toHaveBeenCalled();
    expect(request).toHaveBeenCalledWith(expect.objectContaining({
      url: '/api/v1/statuses/s9',
      method: 'put',
    }));
    const data = request.mock.calls[0][0].data;
    expect(data).not.toHaveProperty('visibility');
    expect(data).not.toHaveProperty('circle_id');
    expect(data).not.toHaveProperty('quote_id');
    expect(data).not.toHaveProperty('status_reference_ids');
    expect(data).not.toHaveProperty('scheduled_at');
    expect(data).not.toHaveProperty('expires_at');
    expect(data).not.toHaveProperty('in_reply_to_id');
    expect(editActions.map(action => action.type)).toEqual(expect.arrayContaining(['COMPOSE_SUBMIT_REQUEST']));
  });

  it('still asks about missing alt text while editing', async () => {
    const request = jest.fn();
    api.mockReturnValue({ request });

    const state = composeState({ compose: { id: 's9' } })
      .setIn(['compose', 'media_attachments'], ImmutableList([
        fromJS({ id: 'm1', type: 'image', description: '' }),
      ]))
      .setIn(['compose', 'references'], ImmutableSet(['ref-1']));

    await dispatchThunk(submitComposeWithCheck({ location: { pathname: '/home' } }, intl), state);

    expect(openModal).toHaveBeenCalledWith('CONFIRM', expect.objectContaining({
      title: 'Add alt text?',
    }));
    expect(request).not.toHaveBeenCalled();
  });

  it('POSTs an ActivityPub audience target without adding it to the text', async () => {
    const request = jest.fn().mockResolvedValue({ data: statusResponse });
    api.mockReturnValue({ request });
    let compose = composerReducer(undefined, applyComposerPostingContext('primary', {
      key: 'protocol:activitypub:audience',
      managed: { hashtags: [], mentions: [] },
      requirements: { followingAccounts: [] },
      constraints: { allowedVisibilities: ['public', 'unlisted'] },
      protocol: {
        activityPub: {
          audience: {
            accountId: '456',
            acct: 'group@example.com',
            enforcement: 'required',
            ruleId: 'fep-1b12-group-audience',
          },
        },
      },
    }));
    compose = compose.set('text', 'Hello').set('privacy', 'public').set('in_reply_to', null);

    await dispatchThunk(
      submitCompose({ location: { pathname: '/home' }, push: jest.fn(), goBack: jest.fn() }),
      composeState().set('compose', compose),
    );

    const data = request.mock.calls[0][0].data;
    expect(request).toHaveBeenCalledWith(expect.objectContaining({
      url: '/api/v1/statuses',
      method: 'post',
    }));
    expect(data.status).toEqual('Hello');
    expect(data.audience_account_id).toEqual('456');
    expect(data.visibility).toEqual('public');
    expect(data.in_reply_to_id).toBeNull();
  });

  it('does not send an audience target for a Fedibird local group mention', async () => {
    const request = jest.fn().mockResolvedValue({ data: statusResponse });
    api.mockReturnValue({ request });
    const compose = composerReducer(undefined, applyComposerPostingContext('primary', groupPostingContext))
      .set('text', 'Hello')
      .set('privacy', 'public')
      .set('in_reply_to', null);
    const state = composeState()
      .set('compose', compose)
      .set('relationships', ImmutableMap({ '123': ImmutableMap({ following: true }) }));

    await dispatchThunk(
      submitCompose({ location: { pathname: '/home' }, push: jest.fn(), goBack: jest.fn() }),
      state,
    );

    const data = request.mock.calls[0][0].data;
    expect(data.status).toEqual('@group Hello');
    expect(data).not.toHaveProperty('audience_account_id');
  });

  it('PUTs an existing status edit without an audience target', async () => {
    const request = jest.fn().mockResolvedValue({ data: { ...statusResponse, id: 's9' } });
    api.mockReturnValue({ request });
    const compose = composerReducer(undefined, applyComposerPostingContext('primary', {
      key: 'protocol:activitypub:audience',
      protocol: {
        activityPub: {
          audience: {
            accountId: '456',
            acct: 'group@example.com',
            enforcement: 'required',
            ruleId: 'fep-1b12-group-audience',
          },
        },
      },
    })).set('id', 's9').set('text', 'Hello').set('draft_audience_account_id', '456');

    await dispatchThunk(
      submitCompose({ location: { pathname: '/home' }, push: jest.fn(), goBack: jest.fn() }),
      composeState().set('compose', compose),
    );

    expect(request).toHaveBeenCalledWith(expect.objectContaining({
      url: '/api/v1/statuses/s9',
      method: 'put',
    }));
    expect(request.mock.calls[0][0].data).not.toHaveProperty('audience_account_id');
    expect(request.mock.calls[0][0].data.status).toEqual('Hello');
  });

  it('POSTs the retained audience when replacing a scheduled status', async () => {
    const request = jest.fn().mockResolvedValue({ data: statusResponse });
    api.mockReturnValue({ request });
    const compose = composerReducer(undefined, applyComposerPostingContext('primary', {
      key: 'protocol:other',
      protocol: {
        activityPub: {
          audience: {
            accountId: '789',
            acct: 'other@example.com',
            enforcement: 'required',
            ruleId: 'fep-1b12-group-audience',
          },
        },
      },
    }))
      .set('text', 'Hello')
      .set('privacy', 'public')
      .set('in_reply_to', null)
      .set('scheduled_status_id', 'sched-1')
      .set('draft_audience_account_id', '456');

    await dispatchThunk(
      submitCompose({ location: { pathname: '/home' }, push: jest.fn(), goBack: jest.fn() }),
      composeState().set('compose', compose),
    );

    const data = request.mock.calls[0][0].data;
    expect(request).toHaveBeenCalledWith(expect.objectContaining({
      url: '/api/v1/statuses',
      method: 'post',
    }));
    expect(data.status).toEqual('Hello');
    expect(data.audience_account_id).toEqual('456');
  });

  it('does not submit a private scheduled draft that retains an audience target', async () => {
    const request = jest.fn().mockResolvedValue({ data: statusResponse });
    api.mockReturnValue({ request });
    const compose = composerReducer(undefined, applyComposerPostingContext('primary', groupPostingContext))
      .set('text', 'Hello')
      .set('privacy', 'private')
      .set('in_reply_to', null)
      .set('media_attachments', ImmutableList())
      .set('references', ImmutableSet())
      .set('scheduled_status_id', 'sched-1')
      .set('draft_audience_account_id', '456');
    const state = composeState().set('compose', compose);
    const router = { location: { pathname: '/home' }, push: jest.fn(), goBack: jest.fn() };

    await dispatchThunk(submitCompose(router), state);
    await dispatchThunk(submitComposeWithCheck(router, intl), state);

    expect(request).not.toHaveBeenCalled();
  });

  it('POSTs public and unlisted scheduled replacements with the retained audience', async () => {
    const request = jest.fn().mockResolvedValue({ data: statusResponse });
    api.mockReturnValue({ request });
    const router = { location: { pathname: '/home' }, push: jest.fn(), goBack: jest.fn() };
    const scheduled = (privacy) => composerReducer(undefined, applyComposerPostingContext('primary', groupPostingContext))
      .set('text', 'Hello')
      .set('privacy', privacy)
      .set('in_reply_to', null)
      .set('media_attachments', ImmutableList())
      .set('references', ImmutableSet())
      .set('scheduled_status_id', 'sched-1')
      .set('draft_audience_account_id', '456')
      .setIn(['context', 'protocol', 'activityPub', 'audience'], ImmutableMap({
        accountId: '789',
        acct: 'other@example.com',
        enforcement: 'required',
        ruleId: 'fep-1b12-group-audience',
      }));

    await dispatchThunk(submitCompose(router), composeState().set('compose', scheduled('public')));
    await dispatchThunk(
      submitComposeWithCheck(router, intl),
      composeState().set('compose', scheduled('unlisted')),
    );

    expect(request).toHaveBeenCalledTimes(2);
    expect(request.mock.calls[0][0]).toEqual(expect.objectContaining({
      url: '/api/v1/statuses',
      method: 'post',
    }));
    expect(request.mock.calls[0][0].data.status).toEqual('Hello');
    expect(request.mock.calls[0][0].data.visibility).toEqual('public');
    expect(request.mock.calls[0][0].data.audience_account_id).toEqual('456');
    expect(request.mock.calls[1][0].data.visibility).toEqual('unlisted');
    expect(request.mock.calls[1][0].data.audience_account_id).toEqual('456');
    expect(request.mock.calls[1][0].data.status).toEqual('Hello');
  });

  const mitraCompose = (privacy, relationships) => {
    const compose = composerReducer(undefined, applyComposerPostingContext('primary', mitraGroupPostingContext))
      .set('text', 'Hello Mitra')
      .set('privacy', privacy)
      .set('in_reply_to', null)
      .set('media_attachments', ImmutableList())
      .set('references', ImmutableSet());

    return composeState()
      .set('compose', compose)
      .set('relationships', relationships || ImmutableMap());
  };

  it('posts a Mitra audience context without adding a mention or requiring a follow', async () => {
    const request = jest.fn().mockResolvedValue({ data: statusResponse });
    api.mockReturnValue({ request });
    const router = { location: { pathname: '/home' }, push: jest.fn(), goBack: jest.fn() };

    await dispatchThunk(submitCompose(router), mitraCompose('public'));
    await dispatchThunk(
      submitComposeWithCheck(router, intl),
      mitraCompose('public', ImmutableMap({ '456': ImmutableMap({ following: false }) })),
    );

    expect(request).toHaveBeenCalledTimes(2);
    request.mock.calls.forEach((call) => {
      expect(call[0]).toEqual(expect.objectContaining({
        url: '/api/v1/statuses',
        method: 'post',
      }));
      expect(call[0].data.status).toEqual('Hello Mitra');
      expect(call[0].data.visibility).toEqual('public');
      expect(call[0].data.audience_account_id).toEqual('456');
      expect(call[0].data.status).not.toContain('@group@mitra.example');
    });
  });

  it('posts an unlisted Mitra audience context', async () => {
    const request = jest.fn().mockResolvedValue({ data: statusResponse });
    api.mockReturnValue({ request });

    await dispatchThunk(
      submitCompose({ location: { pathname: '/home' }, push: jest.fn(), goBack: jest.fn() }),
      mitraCompose('unlisted'),
    );

    expect(request.mock.calls[0][0].data).toEqual(expect.objectContaining({
      status: 'Hello Mitra',
      visibility: 'unlisted',
      audience_account_id: '456',
    }));
  });

  it('does not submit a private Mitra audience context', async () => {
    const request = jest.fn().mockResolvedValue({ data: statusResponse });
    api.mockReturnValue({ request });
    const router = { location: { pathname: '/home' }, push: jest.fn(), goBack: jest.fn() };
    const state = mitraCompose('private');

    await dispatchThunk(submitCompose(router), state);
    await dispatchThunk(submitComposeWithCheck(router, intl), state);

    expect(request).not.toHaveBeenCalled();
  });

  it('does not apply a Mitra audience context while editing an existing status', async () => {
    const request = jest.fn().mockResolvedValue({ data: { ...statusResponse, id: 's9' } });
    api.mockReturnValue({ request });
    const compose = composerReducer(undefined, applyComposerPostingContext('primary', mitraGroupPostingContext))
      .set('id', 's9')
      .set('text', 'Hello Mitra')
      .set('privacy', 'public');

    await dispatchThunk(
      submitCompose({ location: { pathname: '/home' }, push: jest.fn(), goBack: jest.fn() }),
      composeState().set('compose', compose),
    );

    expect(request).toHaveBeenCalledWith(expect.objectContaining({
      url: '/api/v1/statuses/s9',
      method: 'put',
    }));
    expect(request.mock.calls[0][0].data.status).toEqual('Hello Mitra');
    expect(request.mock.calls[0][0].data).not.toHaveProperty('audience_account_id');
  });
});

const router = { location: { pathname: '/home' }, push: jest.fn(), goBack: jest.fn() };

const reduceComposeStore = (state, action) => {
  if (!state || !action || action.type === '@@INIT') {
    return state;
  }

  return state
    .set('compose', composeReducer(state.get('compose'), action))
    .set('userPostingStyles', userPostingStyles(state.get('userPostingStyles'), action));
};

const namedStyle = (id, name) => fromJS({
  id,
  name,
  revision: 1,
  target: { kind: 'none', accountId: null, hashtag: null, label: null },
  defaults: { visibility: 'public' },
  managed: { hashtags: [] },
});

const buildComposeStore = (compose = initialComposerState, styles = ImmutableList()) => createStore(
  reduceComposeStore,
  ImmutableMap({
    compose,
    userPostingStyles: userPostingStyles(undefined, { type: USER_POSTING_STYLES_FETCH_SUCCESS, styles }),
  }),
  applyMiddleware(thunk),
);

const deferRequests = () => {
  const pending = [];
  const request = jest.fn(() => new Promise((resolve, reject) => {
    pending.push({ resolve, reject });
  }));

  api.mockReturnValue({ request });

  return { pending, request };
};

const sentSubmission = compose => ({
  token: compose.get('idempotencyKey'),
  submitId: compose.get('activeSubmitId'),
  instanceId: compose.get('instanceId'),
  selectionGeneration: compose.getIn(['userPostingStyle', 'selectionGeneration']) || 0,
  draftGeneration: compose.get('draftGeneration') || 0,
  text: compose.get('text') || '',
  mediaIds: '',
  surface: null,
  senderIdentityId: compose.getIn(['senderIdentity', 'id']) || null,
  kind: 'new',
});

describe('resending a draft kept after an older success', () => {
  const pollOption = (store, index = 0) => store.getState().getIn(['compose', 'poll', 'options', index]);

  it('posts the edited poll with a new idempotency key and then completes', async () => {
    const { pending, request } = deferRequests();
    const store = buildComposeStore();
    store.dispatch({ type: COMPOSE_CHANGE, text: 'Choose' });
    store.dispatch({ type: COMPOSE_POLL_ADD });
    store.dispatch({ type: COMPOSE_POLL_OPTION_CHANGE, index: 0, title: 'Now' });

    const first = store.dispatch(submitCompose(router));
    const sentKey = request.mock.calls[0][0].headers['Idempotency-Key'];
    expect(request.mock.calls[0][0].data.poll.getIn(['options', 0])).toEqual('Now');

    store.dispatch({ type: COMPOSE_POLL_OPTION_CHANGE, index: 0, title: 'Later' });
    const editedKey = store.getState().getIn(['compose', 'idempotencyKey']);
    expect(editedKey).not.toEqual(sentKey);

    pending[0].resolve({ data: statusResponse });
    await first;

    const kept = store.getState().get('compose');
    expect(kept.get('is_submitting')).toBe(false);
    expect(kept.get('text')).toEqual('Choose');
    expect(pollOption(store)).toEqual('Later');
    expect(kept.get('idempotencyKey')).toEqual(editedKey);
    expect(kept.get('consumedSubmissionToken')).toEqual(sentKey);

    const second = store.dispatch(submitCompose(router));
    expect(request.mock.calls[1][0].headers['Idempotency-Key']).toEqual(editedKey);
    expect(request.mock.calls[1][0].data.poll.getIn(['options', 0])).toEqual('Later');
    expect(request.mock.calls[1][0].headers['Idempotency-Key']).not.toEqual(sentKey);

    pending[1].resolve({ data: { ...statusResponse, id: 's2' } });
    await second;

    const done = store.getState().get('compose');
    expect(done.get('text')).toEqual('');
    expect(done.get('poll')).toBeNull();
    expect(done.get('is_submitting')).toBe(false);
    expect(done.get('idempotencyKey')).not.toEqual(editedKey);
  });

  it('does not roll back a key already replaced by a text or warning edit', async () => {
    const { pending, request } = deferRequests();
    const store = buildComposeStore();
    store.dispatch({ type: COMPOSE_CHANGE, text: 'Hello' });
    store.dispatch({ type: COMPOSE_SPOILERNESS_CHANGE });
    store.dispatch({ type: COMPOSE_SPOILER_TEXT_CHANGE, text: 'before' });

    const first = store.dispatch(submitCompose(router));
    const sentKey = request.mock.calls[0][0].headers['Idempotency-Key'];
    store.dispatch({ type: COMPOSE_SPOILER_TEXT_CHANGE, text: 'after' });
    const editedKey = store.getState().getIn(['compose', 'idempotencyKey']);
    expect(editedKey).not.toEqual(sentKey);

    pending[0].resolve({ data: statusResponse });
    await first;

    const kept = store.getState().get('compose');
    expect(kept.get('idempotencyKey')).toEqual(editedKey);
    expect(kept.get('spoiler_text')).toEqual('after');
    expect(kept.get('text')).toEqual('Hello');
    expect(kept.get('is_submitting')).toBe(false);
  });

  it('keeps the same key when a failed request is retried without edits', async () => {
    const { pending, request } = deferRequests();
    const store = buildComposeStore();
    store.dispatch({ type: COMPOSE_CHANGE, text: 'Retry me' });

    const first = store.dispatch(submitCompose(router));
    const sentKey = request.mock.calls[0][0].headers['Idempotency-Key'];
    pending[0].reject(Object.assign(new Error('network'), { response: undefined }));
    await first;

    expect(store.getState().getIn(['compose', 'idempotencyKey'])).toEqual(sentKey);
    expect(store.getState().getIn(['compose', 'is_submitting'])).toBe(false);
    expect(store.getState().getIn(['compose', 'text'])).toEqual('Retry me');

    const second = store.dispatch(submitCompose(router));
    expect(request.mock.calls[1][0].headers['Idempotency-Key']).toEqual(sentKey);
    expect(request.mock.calls[1][0].data.status).toEqual('Retry me');
    pending[1].resolve({ data: statusResponse });
    await second;

    expect(store.getState().getIn(['compose', 'text'])).toEqual('');
    expect(store.getState().getIn(['compose', 'is_submitting'])).toBe(false);
  });

  it('leaves the key and submitting flag alone for a duplicate, another instance, or a newer send', async () => {
    const { pending, request } = deferRequests();
    const store = buildComposeStore();
    store.dispatch({ type: COMPOSE_CHANGE, text: 'Choose' });
    store.dispatch({ type: COMPOSE_POLL_ADD });
    store.dispatch({ type: COMPOSE_POLL_OPTION_CHANGE, index: 0, title: 'Now' });

    const first = store.dispatch(submitCompose(router));
    const sent = sentSubmission(store.getState().get('compose'));
    const sentKey = store.getState().getIn(['compose', 'idempotencyKey']);

    store.dispatch({
      type: COMPOSE_SUBMIT_SUCCESS,
      submitId: sent.submitId,
      submission: { ...sent, instanceId: 'composer-other' },
    });
    expect(store.getState().getIn(['compose', 'is_submitting'])).toBe(true);
    expect(store.getState().getIn(['compose', 'idempotencyKey'])).toEqual(sentKey);

    store.dispatch({ type: COMPOSE_POLL_OPTION_CHANGE, index: 0, title: 'Later' });
    const editedKey = store.getState().getIn(['compose', 'idempotencyKey']);
    store.dispatch({ type: COMPOSE_SUBMIT_REQUEST, submitId: 'submit-newer' });
    store.dispatch({
      type: COMPOSE_SUBMIT_SUCCESS,
      submitId: sent.submitId,
      submission: sent,
    });
    expect(store.getState().getIn(['compose', 'is_submitting'])).toBe(true);
    expect(store.getState().getIn(['compose', 'activeSubmitId'])).toEqual('submit-newer');
    expect(store.getState().getIn(['compose', 'idempotencyKey'])).toEqual(editedKey);
    expect(pollOption(store)).toEqual('Later');

    store.dispatch({ type: COMPOSE_SUBMIT_REQUEST, submitId: sent.submitId });
    pending[0].resolve({ data: statusResponse });
    await first;

    const keptKey = store.getState().getIn(['compose', 'idempotencyKey']);
    expect(keptKey).toEqual(editedKey);
    expect(store.getState().getIn(['compose', 'text'])).toEqual('Choose');
    expect(request).toHaveBeenCalledTimes(1);

    store.dispatch({
      type: COMPOSE_SUBMIT_SUCCESS,
      submitId: sent.submitId,
      submission: sent,
    });
    expect(store.getState().getIn(['compose', 'idempotencyKey'])).toEqual(keptKey);
    expect(store.getState().getIn(['compose', 'is_submitting'])).toBe(false);
    expect(store.getState().getIn(['compose', 'text'])).toEqual('Choose');
    expect(pollOption(store)).toEqual('Later');
  });

  it('completes a post whose only in-flight change was the usage period', async () => {
    const { pending, request } = deferRequests();
    const once = initialComposerState
      .setIn(['userPostingStyle', 'usageMode'], 'once')
      .setIn(['userPostingStyle', 'selectionKind'], 'style')
      .setIn(['userPostingStyle', 'selectedId'], 'style-b');
    const store = buildComposeStore(once);
    store.dispatch({ type: COMPOSE_CHANGE, text: 'This post' });

    const first = store.dispatch(submitCompose(router));
    const sentKey = request.mock.calls[0][0].headers['Idempotency-Key'];
    store.dispatch(setPostingStyleUsage(PRIMARY_COMPOSER_ID, 'keep'));
    expect(store.getState().getIn(['compose', 'idempotencyKey'])).toEqual(sentKey);
    expect(store.getState().getIn(['compose', 'userPostingStyle', 'usageMode'])).toEqual('keep');

    pending[0].resolve({ data: statusResponse });
    await first;

    const kept = store.getState().get('compose');
    expect(kept.get('text')).toEqual('');
    expect(kept.get('is_submitting')).toBe(false);
    expect(kept.get('userPostingStyle').get('usageMode')).toEqual('keep');
    expect(kept.getIn(['userPostingStyle', 'selectedId'])).toEqual('style-b');
    expect(kept.get('idempotencyKey')).not.toEqual(sentKey);
    expect(kept.get('consumedSubmissionToken')).toEqual(sentKey);

    const back = buildComposeStore(initialComposerState.setIn(['userPostingStyle', 'usageMode'], 'keep').setIn(['userPostingStyle', 'selectionKind'], 'style').setIn(['userPostingStyle', 'selectedId'], 'style-b'));
    const { pending: again, request: againRequest } = deferRequests();
    back.dispatch({ type: COMPOSE_CHANGE, text: 'Once more' });
    const second = back.dispatch(submitCompose(router));
    back.dispatch(setPostingStyleUsage(PRIMARY_COMPOSER_ID, 'once'));
    again[0].resolve({ data: statusResponse });
    await second;

    const restored = back.getState().get('compose');
    expect(restored.get('text')).toEqual('');
    expect(restored.get('is_submitting')).toBe(false);
    expect(restored.getIn(['userPostingStyle', 'usageMode'])).toEqual('usual');
    expect(restored.getIn(['userPostingStyle', 'selectedId'])).toBeNull();
    expect(restored.get('idempotencyKey')).not.toEqual(againRequest.mock.calls[0][0].headers['Idempotency-Key']);
  });

  it('keeps a same-valued style chosen while sending and posts it with a new key', async () => {
    const { pending, request } = deferRequests();
    const store = buildComposeStore(initialComposerState, ImmutableList([
      namedStyle('a', 'Alpha'),
      namedStyle('b', 'Beta'),
    ]));
    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, 'a'));
    store.dispatch({ type: COMPOSE_CHANGE, text: 'Draft' });
    const sentGeneration = store.getState().getIn(['compose', 'userPostingStyle', 'selectionGeneration']);

    const first = store.dispatch(submitCompose(router));
    const sentKey = request.mock.calls[0][0].headers['Idempotency-Key'];

    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, 'b'));
    const during = store.getState().get('compose');
    expect(during.getIn(['userPostingStyle', 'selectedId'])).toEqual('b');
    expect(during.getIn(['userPostingStyle', 'usageMode'])).toEqual('once');
    expect(during.getIn(['userPostingStyle', 'selectionGeneration'])).toBeGreaterThan(sentGeneration);
    expect(during.get('idempotencyKey')).toEqual(sentKey);
    expect(during.get('privacy')).toEqual('public');
    expect(during.get('text')).toEqual('Draft');

    pending[0].resolve({ data: statusResponse });
    await first;

    const kept = store.getState().get('compose');
    expect(kept.get('text')).toEqual('Draft');
    expect(kept.getIn(['userPostingStyle', 'selectedId'])).toEqual('b');
    expect(kept.getIn(['userPostingStyle', 'usageMode'])).toEqual('once');
    expect(kept.getIn(['userPostingStyle', 'snapshot', 'id'])).toEqual('b');
    expect(kept.get('is_submitting')).toBe(false);
    const nextKey = kept.get('idempotencyKey');
    expect(nextKey).not.toEqual(sentKey);

    const second = store.dispatch(submitCompose(router));
    expect(request.mock.calls[1][0].headers['Idempotency-Key']).toEqual(nextKey);
    expect(request.mock.calls[1][0].data.status).toEqual('Draft');
    expect(request.mock.calls[1][0].data.visibility).toEqual('public');
    pending[1].resolve({ data: { ...statusResponse, id: 's2' } });
    await second;

    const done = store.getState().get('compose');
    expect(done.get('text')).toEqual('');
    expect(done.get('is_submitting')).toBe(false);
    expect(done.getIn(['userPostingStyle', 'usageMode'])).toEqual('usual');
  });

  it('keeps a reapplied style, an explicit none, and a return to the same id', async () => {
    const styles = ImmutableList([namedStyle('a', 'Alpha'), namedStyle('b', 'Beta')]);

    const reapplied = buildComposeStore(initialComposerState, styles);
    const { pending: reapplyPending, request: reapplyRequest } = deferRequests();
    await reapplied.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, 'a'));
    reapplied.dispatch({ type: COMPOSE_CHANGE, text: 'Same style' });
    const reapplyGeneration = reapplied.getState().getIn(['compose', 'userPostingStyle', 'selectionGeneration']);
    const reapplySend = reapplied.dispatch(submitCompose(router));
    const reapplyKey = reapplyRequest.mock.calls[0][0].headers['Idempotency-Key'];
    await reapplied.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, 'a'));
    expect(reapplied.getState().getIn(['compose', 'userPostingStyle', 'selectedId'])).toEqual('a');
    expect(reapplied.getState().getIn(['compose', 'userPostingStyle', 'selectionGeneration'])).toBeGreaterThan(reapplyGeneration);
    expect(reapplied.getState().getIn(['compose', 'idempotencyKey'])).toEqual(reapplyKey);
    reapplyPending[0].resolve({ data: statusResponse });
    await reapplySend;
    expect(reapplied.getState().getIn(['compose', 'text'])).toEqual('Same style');
    expect(reapplied.getState().getIn(['compose', 'userPostingStyle', 'selectedId'])).toEqual('a');
    expect(reapplied.getState().getIn(['compose', 'userPostingStyle', 'usageMode'])).toEqual('once');
    expect(reapplied.getState().getIn(['compose', 'idempotencyKey'])).not.toEqual(reapplyKey);

    const cleared = buildComposeStore(initialComposerState, styles);
    const { pending: nonePending, request: noneRequest } = deferRequests();
    await cleared.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, 'a'));
    cleared.dispatch({ type: COMPOSE_CHANGE, text: 'No style' });
    const noneSend = cleared.dispatch(submitCompose(router));
    const noneKey = noneRequest.mock.calls[0][0].headers['Idempotency-Key'];
    await cleared.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, null));
    expect(cleared.getState().getIn(['compose', 'userPostingStyle', 'selectedId'])).toBeNull();
    expect(cleared.getState().getIn(['compose', 'userPostingStyle', 'selectionKind'])).toEqual('none');
    expect(cleared.getState().getIn(['compose', 'privacy'])).toEqual('public');
    expect(cleared.getState().getIn(['compose', 'idempotencyKey'])).toEqual(noneKey);
    nonePending[0].resolve({ data: statusResponse });
    await noneSend;
    expect(cleared.getState().getIn(['compose', 'text'])).toEqual('No style');
    expect(cleared.getState().getIn(['compose', 'userPostingStyle', 'selectedId'])).toBeNull();
    expect(cleared.getState().getIn(['compose', 'userPostingStyle', 'selectionKind'])).toEqual('none');
    expect(cleared.getState().getIn(['compose', 'userPostingStyle', 'usageMode'])).toEqual('once');
    expect(cleared.getState().getIn(['compose', 'idempotencyKey'])).not.toEqual(noneKey);

    const returned = buildComposeStore(initialComposerState, styles);
    const { pending: returnPending, request: returnRequest } = deferRequests();
    await returned.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, 'a'));
    returned.dispatch({ type: COMPOSE_CHANGE, text: 'Back to A' });
    const sentId = returned.getState().getIn(['compose', 'userPostingStyle', 'selectedId']);
    const sentGeneration = returned.getState().getIn(['compose', 'userPostingStyle', 'selectionGeneration']);
    const returnSend = returned.dispatch(submitCompose(router));
    const returnKey = returnRequest.mock.calls[0][0].headers['Idempotency-Key'];
    await returned.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, 'b'));
    await returned.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, 'a'));
    expect(returned.getState().getIn(['compose', 'userPostingStyle', 'selectedId'])).toEqual(sentId);
    expect(returned.getState().getIn(['compose', 'userPostingStyle', 'selectionGeneration'])).toBeGreaterThan(sentGeneration);
    expect(returned.getState().getIn(['compose', 'idempotencyKey'])).toEqual(returnKey);
    returnPending[0].resolve({ data: statusResponse });
    await returnSend;
    expect(returned.getState().getIn(['compose', 'text'])).toEqual('Back to A');
    expect(returned.getState().getIn(['compose', 'userPostingStyle', 'selectedId'])).toEqual('a');
    expect(returned.getState().getIn(['compose', 'userPostingStyle', 'usageMode'])).toEqual('once');
    expect(returned.getState().getIn(['compose', 'idempotencyKey'])).not.toEqual(returnKey);
  });
});
