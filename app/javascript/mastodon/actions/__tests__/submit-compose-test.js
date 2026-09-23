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

import api from '../../api';
import { importFetchedStatus } from '../importer';
import { updateTimeline } from '../timelines';
import { changeUploadCompose, submitCompose } from '../compose';

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

describe('submitCompose', () => {
  beforeEach(() => {
    api.mockReset();
    importFetchedStatus.mockClear();
    updateTimeline.mockClear();
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
    expect(updateTimeline).toHaveBeenCalled();
    expect(importFetchedStatus).not.toHaveBeenCalled();
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
});
