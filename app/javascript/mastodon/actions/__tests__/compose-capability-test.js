import { Map as ImmutableMap, fromJS } from 'immutable';
import { applyMiddleware, createStore } from 'redux';
import { combineReducers } from 'redux-immutable';
import thunk from 'redux-thunk';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

jest.mock('../../api', () => ({
  __esModule: true,
  default: jest.fn(),
}));

jest.mock('../importer', () => ({
  importFetchedAccounts: jest.fn(accounts => ({ type: 'ACCOUNTS_IMPORT', accounts })),
  importFetchedStatus: jest.fn(status => ({ type: 'STATUS_IMPORT', status })),
}));

jest.mock('../../selectors', () => ({
  getHomeVisibilities: () => ['public'],
  getLimitedVisibilities: () => ['private'],
}));

import api from '../../api';
import { changeCompose, changeComposeVisibility, setComposeToStatus, submitComposer, submitComposerWithCheck } from '../compose';
import { applyComposerPostingContext, createComposer, targetComposerAction } from '../composer';
import { POSTING_CONTEXT_FETCH_SUCCESS } from '../posting_contexts';
import { groupPostingContext } from '../../posting_context/fixtures/group_context_fixture';
import { mitraGroupPostingContext } from '../../posting_context/fixtures/mitra_group_context_fixture';
import { buildHashtagTimelinePostingContext } from '../../posting_context/hashtag';
import { selectComposerEffectiveCreateCapability } from '../../posting_context/create_capability';
import composers from '../../reducers/composers';
import relationships from '../../reducers/relationships';
import postingContexts from '../../reducers/posting_contexts';

const router = { push: jest.fn(), goBack: jest.fn() };
const intl = { formatMessage: () => '' };
const statusResponse = {
  id: 's1',
  visibility: 'public',
  in_reply_to_id: null,
  scheduled_at: null,
  tags: [],
  account: { id: 'a1' },
};

const reducer = combineReducers({
  composers,
  relationships,
  posting_contexts: postingContexts,
  timelines: (state = ImmutableMap()) => state,
  meta: (state = ImmutableMap()) => state,
  statuses: (state = ImmutableMap()) => state,
  accounts: (state = ImmutableMap()) => state,
});

const makeStore = () => createStore(reducer, applyMiddleware(thunk));

const discover = (store, accountId, data) => {
  store.dispatch({
    type: POSTING_CONTEXT_FETCH_SUCCESS,
    accountId,
    receivedAt: Date.now(),
    data,
  });
};

const permissions = create => ({
  affiliations: {
    source: 'fep-5219-affiliations',
    snapshot_status: 'fresh',
    fetched_at: '2026-10-07T01:23:45Z',
    relationships: [],
  },
  permissions: { create },
});

const mitraPayload = (createStatus, via = null) => ({
  schema_version: 1,
  account_id: '456',
  status: 'resolved',
  context: {
    key: 'protocol:fep-1b12-group:456',
    managed: { hashtags: [], mentions: [] },
    requirements: { following_accounts: [] },
    constraints: { allowed_visibilities: ['public', 'unlisted'] },
    protocol: {
      activitypub: {
        audience: {
          account_id: '456',
          acct: 'group@mitra.example',
          enforcement: 'required',
          rule_id: 'fep-1b12-group-audience',
        },
      },
    },
  },
  discovery: {
    mechanism: 'nodeinfo_software',
    adapter: 'mitra_group',
    authority: 'compatibility',
  },
  viewer_evidence: permissions({
    status: createStatus,
    source: 'fep-5219',
    via_relationship: via,
    authority: 'protocol',
  }),
});

const prepareMitra = (store, { createStatus = 'unknown', privacy = 'public', via = null } = {}) => {
  store.dispatch(createComposer('composer-a'));
  store.dispatch(targetComposerAction(changeComposeVisibility(privacy), 'composer-a'));
  store.dispatch(targetComposerAction(changeCompose('Hello'), 'composer-a'));
  store.dispatch(applyComposerPostingContext('composer-a', mitraGroupPostingContext, '456'));
  discover(store, '456', mitraPayload(createStatus, via));
};

describe('submit create capability', () => {
  beforeEach(() => {
    api.mockReset();
  });

  it('makes the same attempt decision in submitComposerWithCheck and submitComposer', async () => {
    const request = jest.fn().mockResolvedValue({ data: statusResponse });
    api.mockReturnValue({ request });
    const store = makeStore();

    prepareMitra(store, { createStatus: 'unknown' });
    const before = selectComposerEffectiveCreateCapability(store.getState(), 'composer-a');

    await store.dispatch(submitComposerWithCheck('composer-a', router, intl));
    expect(before.canAttempt).toBe(true);
    expect(request).toHaveBeenCalledTimes(1);
    expect(request.mock.calls[0][0].data.visibility).toEqual('public');

    request.mockClear();
    prepareMitra(store, { createStatus: 'unknown', privacy: 'private' });
    const blocked = selectComposerEffectiveCreateCapability(store.getState(), 'composer-a');

    await store.dispatch(submitComposerWithCheck('composer-a', router, intl));
    await store.dispatch(submitComposer('composer-a', router));

    expect(blocked.canAttempt).toBe(false);
    expect(blocked.reason).toBe('compliance');
    expect(request).not.toHaveBeenCalled();
    expect(store.getState().getIn(['composers', 'byId', 'composer-a', 'text'])).toEqual('Hello');
  });

  it('rechecks the latest state when submitComposer runs after an earlier check', async () => {
    const request = jest.fn().mockResolvedValue({ data: statusResponse });
    api.mockReturnValue({ request });
    const store = makeStore();

    prepareMitra(store, { createStatus: 'allowed', via: 'trusted-poster' });
    expect(selectComposerEffectiveCreateCapability(store.getState(), 'composer-a').canAttempt).toBe(true);

    discover(store, '456', {
      schema_version: 1,
      account_id: '456',
      status: 'unsupported',
      reason: 'no_supported_adapter',
      context: null,
      discovery: { mechanism: null, adapter: null, authority: null },
      viewer_evidence: permissions({
        status: 'allowed',
        source: 'fep-5219',
        via_relationship: 'trusted-poster',
        authority: 'protocol',
      }),
    });

    const latest = selectComposerEffectiveCreateCapability(store.getState(), 'composer-a');

    await store.dispatch(submitComposer('composer-a', router));

    expect(latest.permission.status).toBe('allowed');
    expect(latest.canAttempt).toBe(false);
    expect(latest.reason).toBe('delivery_unsupported');
    expect(request).not.toHaveBeenCalled();
    expect(store.getState().getIn(['composers', 'byId', 'composer-a', 'text'])).toEqual('Hello');
  });

  it('keeps the draft text and attachments when posting fails', async () => {
    api.mockReturnValue({
      request: jest.fn().mockRejectedValue(new Error('offline')),
    });
    const store = makeStore();

    prepareMitra(store, { createStatus: 'allowed', via: 'none' });
    store.dispatch(targetComposerAction({
      type: 'COMPOSE_UPLOAD_SUCCESS',
      media: { id: 'media-1', type: 'image', description: 'tree' },
      file: null,
    }, 'composer-a'));
    const idempotencyKey = store.getState().getIn(['composers', 'byId', 'composer-a', 'idempotencyKey']);

    await store.dispatch(submitComposer('composer-a', router));

    const composer = store.getState().getIn(['composers', 'byId', 'composer-a']);

    expect(composer.get('text')).toEqual('Hello');
    expect(composer.get('media_attachments').size).toBe(1);
    expect(composer.getIn(['media_attachments', 0, 'id'])).toEqual('media-1');
    expect(composer.get('is_submitting')).toBe(false);
    expect(composer.get('idempotencyKey')).toEqual(idempotencyKey);
    expect(composer.get('posting_context_account_id')).toEqual('456');
  });

  it('still materializes managed hashtags and mentions', async () => {
    const request = jest.fn().mockResolvedValue({ data: statusResponse });
    api.mockReturnValue({ request });
    const store = makeStore();

    store.dispatch(createComposer('composer-a'));
    store.dispatch(targetComposerAction(changeCompose('Hello'), 'composer-a'));
    store.dispatch(applyComposerPostingContext('composer-a', buildHashtagTimelinePostingContext('foo')));
    const idempotencyKey = store.getState().getIn(['composers', 'byId', 'composer-a', 'idempotencyKey']);

    await store.dispatch(submitComposer('composer-a', router));

    expect(request.mock.calls[0][0].data.status).toEqual('Hello\n\n#foo');
    expect(request.mock.calls[0][0].headers['Idempotency-Key']).toEqual(idempotencyKey);

    request.mockClear();
    store.dispatch(createComposer('composer-b'));
    store.dispatch(targetComposerAction(changeComposeVisibility('public'), 'composer-b'));
    store.dispatch(targetComposerAction(changeCompose('Hello'), 'composer-b'));
    store.dispatch(applyComposerPostingContext('composer-b', groupPostingContext, '123'));
    store.dispatch({
      type: 'RELATIONSHIPS_FETCH_SUCCESS',
      relationships: [{ id: '123', following: true, requested: false }],
    });
    discover(store, '123', {
      schema_version: 1,
      account_id: '123',
      status: 'resolved',
      context: {
        key: 'builtin:fedibird-group:123',
        managed: { hashtags: [], mentions: [] },
        requirements: { following_accounts: [] },
        constraints: { allowed_visibilities: ['public', 'unlisted'] },
      },
      discovery: {
        mechanism: 'built_in',
        adapter: 'fedibird_group',
        authority: 'server',
      },
    });

    await store.dispatch(submitComposerWithCheck('composer-b', router, intl));

    expect(request.mock.calls[0][0].data.status).toEqual('@group Hello');
    expect(request.mock.calls[0][0].data.visibility).toEqual('public');
  });

  it('does not apply the group create gate to an existing post edit', async () => {
    const request = jest.fn().mockResolvedValue({ data: statusResponse });
    api.mockReturnValue({ request });
    const store = makeStore();

    prepareMitra(store, { createStatus: 'unknown', privacy: 'private' });
    discover(store, '456', {
      schema_version: 1,
      account_id: '456',
      status: 'unsupported',
      reason: 'no_supported_adapter',
      context: null,
      discovery: { mechanism: null, adapter: null, authority: null },
    });
    store.dispatch(targetComposerAction(setComposeToStatus(fromJS({
      id: 'status-9',
      visibility: 'private',
      sensitive: false,
      language: 'en',
      media_attachments: [],
    }), 'Hello', ''), 'composer-a'));

    await store.dispatch(submitComposer('composer-a', router));

    expect(request).toHaveBeenCalled();
    expect(request.mock.calls[0][0].method).toEqual('put');
    expect(request.mock.calls[0][0].data.status).toEqual('Hello');
  });
});
