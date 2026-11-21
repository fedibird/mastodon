/* eslint-disable react/prop-types */

import { act, fireEvent, render } from '@testing-library/react';
import React from 'react';

let mockRequest;
let mockPhase = 'loading';
let mockFailure = null;
let mockAvailability = 'enabled';
let mockMe = '1';
let mockToken = 'token';
const mockSubscribers = new Set();
const mockState = {
  getIn: path => {
    const key = path.join('.');
    if (key === 'emojiMutes.phase') return mockPhase;
    if (key === 'emojiMutes.failure') return mockFailure;
    if (key === 'emojiMutes.availability') return mockAvailability;
    if (key === 'meta.me') return mockMe;
    if (key === 'meta.access_token') return mockToken;
    return undefined;
  },
};
const mockDispatch = jest.fn(action => {
  if (typeof action === 'function') {
    return action(mockDispatch, () => mockState);
  }
  return action;
});
const mockStore = {
  dispatch: mockDispatch,
  getState: () => mockState,
  subscribe: jest.fn(callback => {
    mockSubscribers.add(callback);
    return () => mockSubscribers.delete(callback);
  }),
};
const mockStartSubscriptions = jest.fn(() => jest.fn());
const mockUiMounts = jest.fn();
const mockUiUnmounts = jest.fn();

jest.mock('mastodon/initial_state', () => ({
  __esModule: true,
  default: { meta: { me: '1', access_token: 'token' } },
}));

jest.mock('mastodon/features/emoji/emoji_mute_availability', () => ({
  currentEmojiMuteBoot: jest.fn(() => ({
    availability: 'enabled',
    explicit: true,
    modal: true,
    fetch: true,
    display: 'suppress',
  })),
}));

jest.mock('mastodon/store/configureStore', () => ({
  __esModule: true,
  default: jest.fn(() => mockStore),
}));
jest.mock('mastodon/actions/store', () => ({ hydrateStore: () => ({ type: 'TEST_HYDRATE' }) }));
jest.mock('mastodon/actions/circles', () => ({
  fetchCircles: () => ({ type: 'TEST_CIRCLES' }),
  prefetchCircles: () => ({ type: 'TEST_CIRCLES' }),
}));
jest.mock('mastodon/features/emoji/emoji_picker_preferences', () => ({ preloadEmojiPickersIfNeeded: jest.fn() }));
jest.mock('mastodon/containers/mastodon_subscriptions', () => ({ startMastodonSubscriptions: (...args) => mockStartSubscriptions(...args) }));
jest.mock('mastodon/features/emoji/emoji_mute_store', () => ({ resetEmojiMuteSession: jest.fn() }));
jest.mock('mastodon/actions/emoji_mutes', () => ({
  EMOJI_MUTES_RESET: 'EMOJI_MUTES_RESET',
  invalidateEmojiMuteAsyncWork: jest.fn(),
  retryEmojiMuteLoad: jest.fn(() => () => mockRequest.promise),
  ignoreEmojiMutesThisView: jest.fn(() => ({ type: 'EMOJI_MUTES_IGNORE' })),
  disableEmojiMuteFeature: jest.fn(() => () => Promise.resolve({ enabled: false, explicit: true, applied: true })),
}));
jest.mock('mastodon/locales', () => ({ getLocale: () => ({ localeData: [], messages: {} }) }));
jest.mock('react-intl', () => {
  const ReactMock = require('react');
  return {
    IntlProvider: ({ children }) => <ReactMock.Fragment>{children}</ReactMock.Fragment>,
    FormattedMessage: ({ defaultMessage }) => <span>{defaultMessage}</span>,
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

  return class MockUI extends ReactMock.Component {

    state = { draft: '' };

    componentDidMount() {
      mockUiMounts();
    }

    componentWillUnmount() {
      mockUiUnmounts();
    }

    handleDraftChange = event => {
      this.setState({ draft: event.target.value });
    };

    render() {
      return (
        <div data-testid='webui'>
          timeline
          <div className='scrollable' data-testid='timeline-scroll'>
            <input data-testid='compose-draft' value={this.state.draft} onChange={this.handleDraftChange} />
          </div>
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

import { resetEmojiMuteSession } from 'mastodon/features/emoji/emoji_mute_store';
import { currentEmojiMuteBoot } from 'mastodon/features/emoji/emoji_mute_availability';

const Mastodon = require('../mastodon').default;
const { retryEmojiMuteLoad, ignoreEmojiMutesThisView, disableEmojiMuteFeature } = require('mastodon/actions/emoji_mutes');

const clock = { now: 1_000_000 };

const deferred = () => {
  let resolve;
  let reject;
  const promise = new Promise((done, fail) => {
    resolve = done;
    reject = fail;
  });
  return { promise, resolve, reject };
};

const bootReady = async () => {
  await act(async () => {
    mockPhase = 'ready';
    mockRequest.resolve(null);
    await mockRequest.promise;
  });
};

describe('authenticated emoji mute bootstrap', () => {
  beforeEach(() => {
    clock.now = 1_000_000;
    jest.spyOn(Date, 'now').mockImplementation(() => clock.now);
    mockDispatch.mockClear();
    retryEmojiMuteLoad.mockClear();
    ignoreEmojiMutesThisView.mockClear();
    disableEmojiMuteFeature.mockClear();
    currentEmojiMuteBoot.mockReturnValue({
      availability: 'enabled',
      explicit: true,
      modal: true,
      fetch: true,
      display: 'suppress',
    });
    mockStartSubscriptions.mockClear();
    mockUiMounts.mockClear();
    mockUiUnmounts.mockClear();
    resetEmojiMuteSession.mockClear();
    mockSubscribers.clear();
    mockRequest = deferred();
    mockPhase = 'loading';
    mockFailure = null;
    mockAvailability = 'enabled';
    mockMe = '1';
    mockToken = 'token';
  });

  afterEach(() => {
    Date.now.mockRestore();
  });

  const allowRetry = () => {
    clock.now += 1000;
  };

  const rejectBootstrap = async error => {
    await act(async () => {
      mockRequest.reject(error);
      try {
        await mockRequest.promise;
      } catch (_) {
        // The bootstrap handler owns the error.
      }
    });
  };

  it('mounts the WebUI immediately and fetches mute rules in the background', async () => {
    const view = render(<Mastodon locale='en' />);

    expect(view.getByTestId('webui')).not.toBeNull();
    expect(view.getByTestId('compose-draft')).not.toBeNull();
    expect(retryEmojiMuteLoad).toHaveBeenCalledTimes(1);
    expect(retryEmojiMuteLoad).toHaveBeenCalledWith({ bootstrap: true });
    expect(mockStartSubscriptions).toHaveBeenCalledTimes(1);
    expect(mockUiMounts).toHaveBeenCalledTimes(1);
    expect(view.queryByText('Preparing the interface…')).toBeNull();

    const privacyRoot = view.container.querySelector('.emoji-mutes-privacy-portal');
    expect(privacyRoot).not.toBeNull();
    expect(privacyRoot.parentElement.style.display).not.toBe('contents');
    expect(privacyRoot.style.display).toBe('contents');

    await bootReady();
    expect(view.getByTestId('webui')).not.toBeNull();
    expect(mockUiMounts).toHaveBeenCalledTimes(1);
    view.unmount();
    expect(mockDispatch).toHaveBeenCalledWith({ type: 'EMOJI_MUTES_RESET' });
    expect(mockSubscribers.size).toBe(0);
  });

  it('does not fetch when the feature is known to be off', () => {
    currentEmojiMuteBoot.mockReturnValue({
      availability: 'disabled',
      explicit: true,
      modal: true,
      fetch: false,
      display: 'show',
    });
    const view = render(<Mastodon locale='en' />);

    expect(view.getByTestId('webui')).not.toBeNull();
    expect(retryEmojiMuteLoad).not.toHaveBeenCalled();
    expect(mockStartSubscriptions).toHaveBeenCalledTimes(1);
    view.unmount();
  });

  it('keeps the WebUI mounted when the first GET fails and offers retry, ignore, and off', async () => {
    const view = render(<Mastodon locale='en' />);
    const ui = view.getByTestId('webui');

    await rejectBootstrap(new Error('offline'));

    expect(view.getByTestId('webui')).toBe(ui);
    expect(mockUiUnmounts).not.toHaveBeenCalled();
    expect(view.getByText(/could not be verified/)).not.toBeNull();
    expect(view.getByText('Ignore this time and continue')).not.toBeNull();
    expect(view.getByText(/Every emoji becomes visible, including ones you muted/)).not.toBeNull();
    expect(view.getByText('Turn emoji muting off')).not.toBeNull();

    fireEvent.click(view.getByText('Ignore this time and continue'));
    expect(ignoreEmojiMutesThisView).toHaveBeenCalledTimes(1);

    mockRequest = deferred();
    allowRetry();
    fireEvent.click(view.getByText('Retry loading settings'));
    expect(retryEmojiMuteLoad).toHaveBeenCalledTimes(2);
    expect(retryEmojiMuteLoad).toHaveBeenLastCalledWith({ bootstrap: false });
    expect(view.getByTestId('webui')).toBe(ui);

    await bootReady();
    expect(view.getByTestId('webui')).toBe(ui);
    expect(mockUiMounts).toHaveBeenCalledTimes(1);
    view.unmount();
  });

  it('closes the notice only after emoji muting is confirmed off', async () => {
    const view = render(<Mastodon locale='en' />);
    await rejectBootstrap(new Error('offline'));

    await act(async () => {
      fireEvent.click(view.getByText('Turn emoji muting off'));
      await Promise.resolve();
    });

    expect(view.queryByText(/could not be verified/)).toBeNull();
    expect(view.queryByText(/stayed on because the setting could not be saved/)).toBeNull();
    expect(view.getByTestId('webui')).not.toBeNull();
    view.unmount();
  });

  it('keeps the notice and a recovery path when turning emoji muting off is not confirmed', async () => {
    disableEmojiMuteFeature.mockImplementationOnce(() => () => Promise.resolve({ enabled: true, applied: true, explicit: true }));
    const view = render(<Mastodon locale='en' />);
    await rejectBootstrap(new Error('offline'));

    await act(async () => {
      fireEvent.click(view.getByText('Turn emoji muting off'));
      await Promise.resolve();
    });

    expect(view.getByText(/could not be verified/)).not.toBeNull();
    expect(view.getByText(/stayed on because the setting could not be saved/)).not.toBeNull();
    expect(view.getByText('Retry loading settings')).not.toBeNull();
    expect(view.getByText('Ignore this time and continue')).not.toBeNull();
    expect(view.getByText('Turn emoji muting off')).not.toBeNull();
    expect(view.getByTestId('webui')).not.toBeNull();
    view.unmount();
  });

  it('keeps a failed save from looking like emoji muting turned off', async () => {
    disableEmojiMuteFeature.mockImplementationOnce(() => () => Promise.reject(new Error('not saved')));
    const view = render(<Mastodon locale='en' />);
    await rejectBootstrap(new Error('offline'));

    await act(async () => {
      fireEvent.click(view.getByText('Turn emoji muting off'));
      await Promise.resolve();
    });

    expect(view.getByText(/stayed on because the setting could not be saved/)).not.toBeNull();
    expect(view.getByTestId('webui')).not.toBeNull();
    view.unmount();
  });

  it('keeps the WebUI up for an expired or forbidden session and hides retry', async () => {
    const unauthorized = render(<Mastodon locale='en' />);
    await rejectBootstrap(Object.assign(new Error('unauthorized'), { response: { status: 401 } }));

    expect(unauthorized.getByTestId('webui')).not.toBeNull();
    expect(unauthorized.getByText(/session expired/i)).not.toBeNull();
    expect(unauthorized.getByText('Reload and sign in')).not.toBeNull();
    expect(unauthorized.queryByText('Retry loading settings')).toBeNull();
    expect(unauthorized.getByText('Ignore this time and continue')).not.toBeNull();
    expect(unauthorized.getByText('Turn emoji muting off')).not.toBeNull();
    unauthorized.unmount();

    mockRequest = deferred();
    const forbiddenView = render(<Mastodon locale='en' />);
    await rejectBootstrap(Object.assign(new Error('forbidden'), { response: { status: 403 } }));

    expect(forbiddenView.getByTestId('webui')).not.toBeNull();
    expect(forbiddenView.getByText(/cannot read emoji mute settings/i)).not.toBeNull();
    expect(forbiddenView.queryByText('Retry loading settings')).toBeNull();
    expect(forbiddenView.getByText('Ignore this time and continue')).not.toBeNull();
    forbiddenView.unmount();
  });

  it('ignores a retry click until the quiet period has elapsed, then allows one', async () => {
    const view = render(<Mastodon locale='en' />);
    await rejectBootstrap(new Error('offline'));

    const callsBefore = retryEmojiMuteLoad.mock.calls.length;
    fireEvent.click(view.getByText('Retry loading settings'));
    expect(retryEmojiMuteLoad).toHaveBeenCalledTimes(callsBefore);

    allowRetry();
    mockRequest = deferred();
    fireEvent.click(view.getByText('Retry loading settings'));
    expect(retryEmojiMuteLoad).toHaveBeenCalledTimes(callsBefore + 1);
    view.unmount();
  });

  it('removes the old viewer DOM before clearing a changed session', async () => {
    const view = render(<Mastodon locale='en' />);
    await bootReady();
    fireEvent.change(view.getByTestId('compose-draft'), { target: { value: 'pending draft' } });

    act(() => {
      mockMe = 'another-account';
      mockSubscribers.forEach(listener => listener());
    });

    expect(view.queryByTestId('webui')).toBeNull();
    expect(view.getByText(/Your account changed/)).not.toBeNull();
    expect(view.queryByText('Ignore this time and continue')).toBeNull();
    expect(resetEmojiMuteSession).toHaveBeenCalled();
    expect(mockDispatch).toHaveBeenCalledWith({ type: 'EMOJI_MUTES_RESET' });
    view.unmount();
  });
});
