import { fromJS, List as ImmutableList, Map as ImmutableMap, Set as ImmutableSet } from 'immutable';

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
import { changeUploadCompose, submitCompose, submitComposeWithCheck } from '../compose';
import { applyComposerPostingContext } from '../composer';
import { groupPostingContext } from '../../posting_context/fixtures/group_context_fixture';
import composerReducer from '../../reducers/composer';

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
    expect(data.searchability).toEqual('public');
    expect(data.in_reply_to_id).toEqual('reply-1');
    expect(data.language).toEqual('ja');
    expect(updateTimeline).toHaveBeenCalled();
    expect(importFetchedStatus).not.toHaveBeenCalled();
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
});
