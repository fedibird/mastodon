import { List as ImmutableList, Map as ImmutableMap } from 'immutable';

import api from '../../api';
import { externalFeedSession } from '../../external_feeds/session';
import { discardExternalFeedSessionForTests, noteExternalStatusStream, receiveExternalFeedChanged } from '../external_feeds';
import { TIMELINE_EXTERNAL_RECONCILE } from '../timelines';

jest.mock('../../api', () => jest.fn());

const state = ImmutableMap({
  externalFeeds: ImmutableMap({ permitted: true }),
  timelines: ImmutableMap({
    home: ImmutableMap({
      items: ImmutableList(['10', '9']),
      pendingItems: ImmutableList(),
    }),
  }),
  statuses: ImmutableMap({
    10: ImmutableMap({ visibility: 'external' }),
    9: ImmutableMap({ visibility: 'public' }),
  }),
  settings: ImmutableMap({
    home: ImmutableMap({ shows: ImmutableMap() }),
    mixes: ImmutableList(),
  }),
  mix_timelines: ImmutableMap(),
});

const flush = () => new Promise(resolve => {
  setTimeout(resolve, 0);
});

describe('external feed reconcile responses', () => {
  let post;

  beforeEach(() => {
    post = jest.fn();
    api.mockImplementation(() => ({
      post,
      get: jest.fn(() => Promise.resolve({ status: 200, data: [] })),
    }));
  });

  afterEach(() => {
    discardExternalFeedSessionForTests();
  });

  const dispatchControl = async (extraDispatch) => {
    const actions = [];
    const dispatch = (action) => {
      if (typeof action === 'function') {
        return action(dispatch, () => state);
      }

      actions.push(action);
      if (extraDispatch) {
        extraDispatch(action);
      }

      return action;
    };

    externalFeedSession.open('home', { targets: [{ type: 'home' }] });
    dispatch(receiveExternalFeedChanged({
      version: 1,
      reason: 'routes_updated',
      targets: [{ type: 'home' }],
      feed_routes_revision: '4',
      subscription_id: '9',
    }));
    await flush();
    return actions;
  };

  it('drops a membership response after the view is closed and reopened', async () => {
    let resolvePost;
    post.mockImplementation(() => new Promise(resolve => {
      resolvePost = resolve;
    }));
    const actions = [];
    const dispatch = (action) => {
      if (typeof action === 'function') {
        return action(dispatch, () => state);
      }

      actions.push(action);
      return action;
    };
    const first = externalFeedSession.open('home', { targets: [{ type: 'home' }] });

    dispatch(receiveExternalFeedChanged({
      version: 1,
      reason: 'routes_updated',
      targets: [{ type: 'home' }],
      feed_routes_revision: '4',
      subscription_id: '9',
    }));
    await flush();
    externalFeedSession.close('home', first);
    externalFeedSession.open('home', { targets: [{ type: 'home' }] });
    resolvePost({
      status: 200,
      data: { outcome: 'complete', results: [{ id: '10', outcome: 'not_in_source' }, { id: '9', outcome: 'not_found' }] },
    });
    await flush();
    await flush();

    expect(actions.some(action => action.type === TIMELINE_EXTERNAL_RECONCILE)).toBe(false);
  });

  it('does not apply a stale not_in_source after a stream edit', async () => {
    let resolvePost;
    post.mockImplementation(() => new Promise(resolve => {
      resolvePost = resolve;
    }));
    const actions = await dispatchControl();

    noteExternalStatusStream('10');
    resolvePost({
      status: 200,
      data: {
        outcome: 'complete',
        results: [
          { id: '10', outcome: 'not_in_source' },
          { id: '9', outcome: 'not_found' },
        ],
      },
    });
    await flush();
    await flush();

    const removed = actions.filter(action => action.type === TIMELINE_EXTERNAL_RECONCILE).flatMap(action => action.removeIds || []);

    expect(removed).toEqual(['9']);
    expect(removed).not.toContain('10');
  });

  it.each([
    ['429', () => Promise.reject({ response: { status: 429 } })],
    ['206', () => Promise.resolve({ status: 206, data: { outcome: 'partial', results: [{ id: '10', outcome: 'not_in_source' }] } })],
    ['unknown', () => Promise.resolve({ status: 200, data: { outcome: 'partial', results: [{ id: '10', outcome: 'unknown', reason: 'outside_retained_range' }] } })],
  ])('does not remove a displayed id on %s', async (_label, responder) => {
    post.mockImplementation(responder);
    const actions = await dispatchControl();

    await flush();
    await flush();

    expect(actions.some(action => action.type === TIMELINE_EXTERNAL_RECONCILE)).toBe(false);
  });
});
