/* eslint-disable react/prop-types */

import { act, fireEvent, render } from '@testing-library/react';
import React from 'react';

const gets = [];
const mockHarness = { dispatch: null, getState: null };

const deferred = () => {
  let resolve;
  let reject;
  const promise = new Promise((done, fail) => {
    resolve = done;
    reject = fail;
  });
  return { promise, resolve, reject };
};

const documentFor = revision => ({
  data: { revision, enabled: true, explicit: true, emoji_mutes: [] },
});

jest.mock('mastodon/initial_state_data', () => ({
  meta: {
    me: '1',
    access_token: 'token',
    emoji_mute_enabled: true,
    emoji_mute_enabled_known: true,
    emoji_mute_enabled_explicit: true,
    emoji_mute_modal: true,
  },
}));

jest.mock('mastodon/api', () => {
  const get = jest.fn();
  return { __esModule: true, default: jest.fn(() => ({ get })) };
});

jest.mock('mastodon/store/configureStore', () => {
  const ImmutableMapLocal = require('immutable').Map;
  const emojiMutesReducer = require('mastodon/reducers/emoji_mutes').default;
  const subscribers = new Set();
  let state = ImmutableMapLocal({
    emojiMutes: emojiMutesReducer(undefined, { type: '@@INIT' }),
    meta: ImmutableMapLocal({ me: '1', access_token: 'token' }),
  });
  const reduce = action => state.set('emojiMutes', emojiMutesReducer(state.get('emojiMutes'), action));
  const dispatch = action => {
    if (typeof action === 'function') {
      return action(dispatch, () => state);
    }

    state = reduce(action);
    subscribers.forEach(listener => listener());
    return action;
  };
  mockHarness.dispatch = dispatch;
  mockHarness.getState = () => state;
  return {
    __esModule: true,
    default: jest.fn(() => ({
      dispatch,
      getState: () => state,
      subscribe: listener => {
        subscribers.add(listener);
        return () => subscribers.delete(listener);
      },
    })),
  };
});

jest.mock('mastodon/actions/store', () => ({ hydrateStore: () => ({ type: 'TEST_HYDRATE' }) }));
jest.mock('mastodon/actions/circles', () => ({
  fetchCircles: () => ({ type: 'TEST_CIRCLES' }),
  prefetchCircles: () => ({ type: 'TEST_CIRCLES' }),
}));
jest.mock('mastodon/actions/custom_emojis', () => ({ ensureCustomEmojis: () => ({ type: 'TEST_EMOJIS' }) }));
jest.mock('mastodon/features/emoji/emoji_picker_preferences', () => ({ preloadEmojiPickersIfNeeded: jest.fn() }));
jest.mock('mastodon/containers/mastodon_subscriptions', () => ({ startMastodonSubscriptions: jest.fn(() => jest.fn()) }));
jest.mock('mastodon/locales', () => ({ getLocale: () => ({ localeData: [], messages: {} }) }));
jest.mock('react-intl', () => {
  const ReactMock = require('react');
  return {
    IntlProvider: ({ children }) => <ReactMock.Fragment>{children}</ReactMock.Fragment>,
    FormattedMessage: ({ defaultMessage }) => <span>{defaultMessage}</span>,
    defineMessages: messages => messages,
    addLocaleData: jest.fn(),
  };
});
jest.mock('react-router-dom', () => ({
  BrowserRouter: ({ children }) => <div>{children}</div>,
  Route: ({ component: Component }) => <Component />,
}));
jest.mock('react-router-scroll-4', () => ({ ScrollContext: ({ children }) => <div>{children}</div> }));
jest.mock('mastodon/features/ui', () => {
  const ReactMock = require('react');
  const Notice = require('mastodon/components/emoji_mute_load_notice').default;

  return class MockUI extends ReactMock.Component {

    render() {
      return (
        <div data-testid='webui'>
          <Notice placement='compose-panel' />
        </div>
      );
    }

  };
});
jest.mock('mastodon/components/error_boundary', () => ({ children }) => <div>{children}</div>);
jest.mock('mastodon/features/embedded_rails_settings/navigation', () => ({
  settingsReturnScroll: () => null,
  settleSettingsReturnScroll: jest.fn(),
}));

import api from 'mastodon/api';
import { syncEmojiMutes } from 'mastodon/actions/emoji_mutes';
import { resetEmojiMuteStoreForTests } from 'mastodon/features/emoji/emoji_mute_store';

const Mastodon = require('../mastodon').default;

const clock = { now: 1_000_000 };

const notice = view => view.container.querySelector('.emoji-mute-load-notice');

describe('obsolete emoji mute retry', () => {
  beforeEach(() => {
    clock.now = 1_000_000;
    jest.spyOn(Date, 'now').mockImplementation(() => clock.now);
    gets.length = 0;
    resetEmojiMuteStoreForTests();
    api().get.mockReset();
    api().get.mockImplementation(url => {
      if (url === '/api/v1/fedibird/emoji_mutes') {
        const pending = deferred();
        gets.push(pending);
        return pending.promise;
      }

      return Promise.resolve({ data: [] });
    });
  });

  afterEach(() => {
    Date.now.mockRestore();
  });

  const failInitial = async view => {
    await act(async () => {
      gets[0].reject(new Error('offline'));
      try {
        await gets[0].promise;
      } catch (error) {
        // The bootstrap handler owns the rejection.
      }
    });
    expect(notice(view)).not.toBeNull();
    clock.now += 1000;
  };

  it('keeps the card hidden while the newest request is in flight and shows it only when that request fails', async () => {
    const view = render(<Mastodon locale='en' />);

    expect(notice(view)).toBeNull();
    await failInitial(view);
    expect(notice(view).textContent).toContain('Couldn\'t load emoji mutes');
    view.unmount();
  });

  it('does not restore the warning after an older retry fails once a newer sync has succeeded', async () => {
    const view = render(<Mastodon locale='en' />);
    await failInitial(view);

    await act(async () => {
      fireEvent.click(view.getByText('Try again'));
    });

    expect(notice(view)).toBeNull();
    const older = gets[1];
    const newer = mockHarness.dispatch(syncEmojiMutes({ changed: { revision: '2' } }));

    await act(async () => {
      gets[2].resolve(documentFor('2'));
      await newer;
    });

    await act(async () => {
      older.reject(Object.assign(new Error('unauthorized'), { response: { status: 401 } }));
      try {
        await older.promise;
      } catch (error) {
        // The superseded retry rejects after the newer document is applied.
      }
    });

    expect(notice(view)).toBeNull();
    expect(mockHarness.getState().getIn(['emojiMutes', 'phase'])).toBe('ready');
    expect(mockHarness.getState().getIn(['emojiMutes', 'failure'])).toBeNull();
    expect(view.container.textContent).not.toContain('Reload and sign in');
    view.unmount();
  });

  it('waits for the newer sync when the older retry fails first, and shows an error only if the newer sync fails', async () => {
    const view = render(<Mastodon locale='en' />);
    await failInitial(view);

    await act(async () => {
      fireEvent.click(view.getByText('Try again'));
    });

    const older = gets[1];
    const newer = mockHarness.dispatch(syncEmojiMutes({ changed: { revision: '2' } }));

    await act(async () => {
      older.reject(new Error('offline'));
      try {
        await older.promise;
      } catch (error) {
        // The older request is no longer the one the notice follows.
      }
    });

    expect(notice(view)).toBeNull();
    expect(mockHarness.getState().getIn(['emojiMutes', 'phase'])).not.toBe('error');

    await act(async () => {
      gets[2].reject(new Error('offline'));
      try {
        await newer;
      } catch (error) {
        // The stream caller discards this rejection. Redux still records it.
      }
    });

    expect(notice(view)).not.toBeNull();
    expect(notice(view).textContent).toContain('Couldn\'t load emoji mutes');
    expect(view.container.textContent).not.toContain('Reload and sign in');
    view.unmount();
  });

  const flush = async () => {
    for (let step = 0; step < 8; step += 1) {
      await Promise.resolve();
    }
  };

  it('does not show an error or start the cooldown when an older success finishes during a newer sync', async () => {
    const view = render(<Mastodon locale='en' />);
    await failInitial(view);

    await act(async () => {
      fireEvent.click(view.getByText('Try again'));
    });

    const older = gets[1];
    const newer = mockHarness.dispatch(syncEmojiMutes({ changed: { revision: '2' } }));

    await act(async () => {
      older.resolve(documentFor('1'));
      await older.promise;
      await flush();
    });

    expect(notice(view)).toBeNull();
    expect(mockHarness.getState().getIn(['emojiMutes', 'phase'])).not.toBe('error');
    expect(mockHarness.getState().getIn(['emojiMutes', 'phase'])).not.toBe('ready');
    expect(mockHarness.getState().getIn(['emojiMutes', 'failure'])).toBeNull();

    await act(async () => {
      gets[2].reject(new Error('offline'));
      try {
        await newer;
      } catch (error) {
        // The newer request owns the notice.
      }
      await flush();
    });

    expect(notice(view)).not.toBeNull();
    expect(notice(view).textContent).toContain('Couldn\'t load emoji mutes');
    expect(view.container.textContent).not.toContain('Reload and sign in');

    const started = gets.length;
    await act(async () => {
      fireEvent.click(view.getByText('Try again'));
    });
    expect(gets.length).toBe(started + 1);
    await act(async () => {
      gets[started].resolve(documentFor('3'));
      await flush();
    });
    view.unmount();
  });

  it('hides the previous card during a sync that this component did not start, and shows it again only after that sync fails', async () => {
    const view = render(<Mastodon locale='en' />);
    await failInitial(view);
    expect(notice(view)).not.toBeNull();

    let newer;
    act(() => {
      newer = mockHarness.dispatch(syncEmojiMutes());
    });

    expect(notice(view)).toBeNull();
    expect(mockHarness.getState().getIn(['emojiMutes', 'phase'])).toBe('loading');

    await act(async () => {
      gets[1].reject(new Error('offline'));
      try {
        await newer;
      } catch (error) {
        // The stream caller discards this rejection.
      }
      await flush();
    });

    expect(mockHarness.getState().getIn(['emojiMutes', 'phase'])).toBe('error');
    expect(notice(view)).not.toBeNull();
    expect(notice(view).textContent).toContain('Couldn\'t load emoji mutes');
    view.unmount();
  });

  const failNewerFirst = async view => {
    await failInitial(view);

    await act(async () => {
      fireEvent.click(view.getByText('Try again'));
    });

    const older = gets[1];
    const newer = mockHarness.dispatch(syncEmojiMutes({ changed: { revision: '2' } }));

    await act(async () => {
      gets[2].reject(new Error('offline'));
      try {
        await newer;
      } catch (error) {
        // The newer request owns the notice even while the older one is open.
      }
      await flush();
    });

    expect(notice(view)).not.toBeNull();
    expect(notice(view).textContent).toContain('Couldn\'t load emoji mutes');
    expect(mockHarness.getState().getIn(['emojiMutes', 'phase'])).toBe('error');
    expect(mockHarness.getState().getIn(['emojiMutes', 'failure'])).toBe('unavailable');
    expect(mockHarness.getState().getIn(['emojiMutes', 'display'])).toBe('suppress');
    return older;
  };

  const expectNewerFailureUnchanged = view => {
    expect(notice(view)).not.toBeNull();
    expect(notice(view).textContent).toContain('Couldn\'t load emoji mutes');
    expect(view.container.textContent).not.toContain('Reload and sign in');
    expect(mockHarness.getState().getIn(['emojiMutes', 'phase'])).toBe('error');
    expect(mockHarness.getState().getIn(['emojiMutes', 'failure'])).toBe('unavailable');
    expect(mockHarness.getState().getIn(['emojiMutes', 'display'])).toBe('suppress');
  };

  it('shows the newer failure before the older request succeeds, and keeps that failure', async () => {
    const view = render(<Mastodon locale='en' />);
    const older = await failNewerFirst(view);

    await act(async () => {
      older.resolve(documentFor('1'));
      await older.promise;
      await flush();
    });

    expectNewerFailureUnchanged(view);
    const started = gets.length;
    await act(async () => {
      fireEvent.click(view.getByText('Try again'));
    });
    expect(gets.length).toBe(started + 1);
    await act(async () => {
      gets[started].resolve(documentFor('3'));
      await flush();
    });
    view.unmount();
  });

  it('starts another retry while the older request is still pending, and that request does not change it', async () => {
    const view = render(<Mastodon locale='en' />);
    const older = await failNewerFirst(view);
    const started = gets.length;

    await act(async () => {
      fireEvent.click(view.getByText('Try again'));
    });

    expect(gets.length).toBe(started + 1);
    expect(notice(view)).toBeNull();
    const phaseWhileCurrent = mockHarness.getState().getIn(['emojiMutes', 'phase']);
    const failureWhileCurrent = mockHarness.getState().getIn(['emojiMutes', 'failure']);

    await act(async () => {
      older.resolve(documentFor('1'));
      await older.promise;
      await flush();
    });

    expect(notice(view)).toBeNull();
    expect(mockHarness.getState().getIn(['emojiMutes', 'phase'])).toBe(phaseWhileCurrent);
    expect(mockHarness.getState().getIn(['emojiMutes', 'failure'])).toBe(failureWhileCurrent);
    expect(view.container.textContent).not.toContain('Reload and sign in');

    await act(async () => {
      gets[started].reject(new Error('offline'));
      await flush();
    });

    expectNewerFailureUnchanged(view);
    view.unmount();
  });

  it('shows the newer failure before an older 401, and does not ask for sign-in', async () => {
    const view = render(<Mastodon locale='en' />);
    const older = await failNewerFirst(view);

    await act(async () => {
      older.reject(Object.assign(new Error('unauthorized'), { response: { status: 401 } }));
      try {
        await older.promise;
      } catch (error) {
        // The superseded 401 does not own the notice.
      }
      await flush();
    });

    expectNewerFailureUnchanged(view);
    view.unmount();
  });

  it('shows the newer failure before an older 500, and keeps that failure', async () => {
    const view = render(<Mastodon locale='en' />);
    const older = await failNewerFirst(view);

    await act(async () => {
      older.reject(new Error('offline'));
      try {
        await older.promise;
      } catch (error) {
        // The superseded 500 does not own the notice.
      }
      await flush();
    });

    expectNewerFailureUnchanged(view);
    view.unmount();
  });

  it('shows a failure when a stream sync is answered with an older revision', async () => {
    const view = render(<Mastodon locale='en' />);
    await failInitial(view);

    let newer;
    act(() => {
      newer = mockHarness.dispatch(syncEmojiMutes({ changed: { revision: '2' } }));
    });

    expect(notice(view)).toBeNull();

    await act(async () => {
      gets[1].resolve(documentFor('1'));
      await newer;
      await flush();
    });

    expect(notice(view)).not.toBeNull();
    expect(notice(view).textContent).toContain('Couldn\'t load emoji mutes');
    expect(mockHarness.getState().getIn(['emojiMutes', 'phase'])).toBe('error');
    expect(mockHarness.getState().getIn(['emojiMutes', 'failure'])).toBe('unavailable');
    expect(mockHarness.getState().getIn(['emojiMutes', 'display'])).toBe('suppress');
    expect(mockHarness.getState().getIn(['emojiMutes', 'appliedRevision'])).toBeNull();
    view.unmount();
  });
});
