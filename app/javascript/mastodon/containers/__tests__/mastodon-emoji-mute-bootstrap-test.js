/* eslint-disable react/prop-types */

import { act, fireEvent, render, waitFor } from '@testing-library/react';
import React from 'react';

let mockRequest;
let mockPhase = 'loading';
let mockFailure = null;
let mockAvailability = 'enabled';
let mockDisplay = 'suppress';
let mockMe = '1';
let mockToken = 'token';
const mockSubscribers = new Set();
const mockState = {
  getIn: path => {
    const key = path.join('.');
    if (key === 'emojiMutes.phase') return mockPhase;
    if (key === 'emojiMutes.failure') return mockFailure;
    if (key === 'emojiMutes.availability') return mockAvailability;
    if (key === 'emojiMutes.display') return mockDisplay;
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
  ignoreEmojiMutesThisView: jest.fn(() => () => {
    mockAvailability = 'temporary_ignore';
    mockDisplay = 'show';
    mockSubscribers.forEach(listener => listener());
  }),
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
  const Notice = require('mastodon/components/emoji_mute_load_notice').default;

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
          <Notice placement='compose-panel' />
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
const { scrubVisibleEmojiIfUnverified } = require('../mastodon');

const registeredEmojiMuteGuard = Array.from(mockSubscribers).find(listener => listener === scrubVisibleEmojiIfUnverified);
const { resetEmojiMuteLiveDomProbe } = require('mastodon/features/emoji/emoji_mute_live_dom');
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
    scrubVisibleEmojiIfUnverified.reset();
    resetEmojiMuteLiveDomProbe();
    mockRequest = deferred();
    mockPhase = 'loading';
    mockFailure = null;
    mockAvailability = 'enabled';
    mockDisplay = 'suppress';
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
    expect(view.container.querySelector('.emoji-mutes-bootstrap')).toBeNull();
    const portal = view.container.querySelector('.emoji-mutes-privacy-portal');
    expect(portal.querySelector('.emoji-mute-load-notice')).not.toBeNull();
    expect(portal.querySelector('.emoji-mute-load-notice').getAttribute('data-placement')).toBe('compose-panel');
    expect(view.getByText(/Emoji stay hidden until the settings check finishes/)).not.toBeNull();
    expect(view.getByText('Ignore this time')).not.toBeNull();
    expect(view.getByText('Ignoring this also shows emoji you muted.')).not.toBeNull();
    expect(view.getByText('Turn the feature off')).not.toBeNull();

    const fetchesBeforeIgnore = retryEmojiMuteLoad.mock.calls.length;

    fireEvent.click(view.getByText('Ignore this time'));
    expect(ignoreEmojiMutesThisView).toHaveBeenCalledTimes(1);
    await waitFor(() => expect(view.getByText(/ignored in this tab for this account/)).not.toBeNull());
    expect(view.queryByText('Try again')).toBeNull();
    expect(retryEmojiMuteLoad).toHaveBeenCalledTimes(fetchesBeforeIgnore);
    expect(view.getByTestId('webui')).toBe(ui);
    view.unmount();
  });

  it('retries a failed load while the notice is still an error', async () => {
    const view = render(<Mastodon locale='en' />);
    const ui = view.getByTestId('webui');

    await rejectBootstrap(new Error('offline'));
    expect(view.getByText('Try again')).not.toBeNull();

    mockRequest = deferred();
    allowRetry();
    fireEvent.click(view.getByText('Try again'));
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
      fireEvent.click(view.getByText('Turn the feature off'));
      await Promise.resolve();
    });

    expect(view.queryByText(/Emoji stay hidden until the settings check finishes/)).toBeNull();
    expect(view.queryByText(/stayed on because the setting could not be saved/)).toBeNull();
    expect(view.getByTestId('webui')).not.toBeNull();
    view.unmount();
  });

  it('keeps the notice and a recovery path when turning emoji muting off is not confirmed', async () => {
    disableEmojiMuteFeature.mockImplementationOnce(() => () => Promise.resolve({ enabled: true, applied: true, explicit: true }));
    const view = render(<Mastodon locale='en' />);
    await rejectBootstrap(new Error('offline'));

    await act(async () => {
      fireEvent.click(view.getByText('Turn the feature off'));
      await Promise.resolve();
    });

    expect(view.getByText(/Emoji stay hidden until the settings check finishes/)).not.toBeNull();
    expect(view.getByText(/stayed on because the setting could not be saved/)).not.toBeNull();
    expect(view.getByText('Try again')).not.toBeNull();
    expect(view.getByText('Ignore this time')).not.toBeNull();
    expect(view.getByText('Turn the feature off')).not.toBeNull();
    expect(view.getByTestId('webui')).not.toBeNull();
    view.unmount();
  });

  it('keeps a failed save from looking like emoji muting turned off', async () => {
    disableEmojiMuteFeature.mockImplementationOnce(() => () => Promise.reject(new Error('not saved')));
    const view = render(<Mastodon locale='en' />);
    await rejectBootstrap(new Error('offline'));

    await act(async () => {
      fireEvent.click(view.getByText('Turn the feature off'));
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
    expect(unauthorized.queryByText('Try again')).toBeNull();
    expect(unauthorized.getByText('Ignore this time')).not.toBeNull();
    expect(unauthorized.getByText('Turn the feature off')).not.toBeNull();
    unauthorized.unmount();

    mockRequest = deferred();
    const forbiddenView = render(<Mastodon locale='en' />);
    await rejectBootstrap(Object.assign(new Error('forbidden'), { response: { status: 403 } }));

    expect(forbiddenView.getByTestId('webui')).not.toBeNull();
    expect(forbiddenView.getByText(/cannot read emoji mute settings/i)).not.toBeNull();
    expect(forbiddenView.queryByText('Try again')).toBeNull();
    expect(forbiddenView.getByText('Ignore this time')).not.toBeNull();
    forbiddenView.unmount();
  });

  it('ignores a retry click until the quiet period has elapsed, then allows one', async () => {
    const view = render(<Mastodon locale='en' />);
    await rejectBootstrap(new Error('offline'));

    const callsBefore = retryEmojiMuteLoad.mock.calls.length;
    fireEvent.click(view.getByText('Try again'));
    expect(retryEmojiMuteLoad).toHaveBeenCalledTimes(callsBefore);

    allowRetry();
    mockRequest = deferred();
    fireEvent.click(view.getByText('Try again'));
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
    expect(view.container.querySelector('.emoji-mute-load-notice').getAttribute('data-placement')).toBe('session');
    expect(view.queryByText('Ignore this time')).toBeNull();
    expect(resetEmojiMuteSession).toHaveBeenCalled();
    expect(mockDispatch).toHaveBeenCalledWith({ type: 'EMOJI_MUTES_RESET' });
    view.unmount();
  });

  it('scrubs through the registered subscriber before React commits a suppress transition', async () => {
    expect(registeredEmojiMuteGuard).toBe(scrubVisibleEmojiIfUnverified);
    const previousDispatch = mockDispatch.getMockImplementation();

    mockDispatch.mockImplementation(action => {
      if (typeof action === 'function') {
        return action(mockDispatch, () => mockState);
      }

      registeredEmojiMuteGuard();
      return action;
    });
    mockDisplay = 'apply';
    const view = render(<Mastodon locale='en' />);
    await bootReady();
    const surface = view.getByTestId('webui');

    surface.insertAdjacentHTML('beforeend', '<p>Hello 👌</p><img alt="👍" src="/emoji/1f44d.svg">');
    mockDisplay = 'suppress';
    mockPhase = 'stale';

    let srcBeforeCommit = 'unset';

    act(() => {
      mockDispatch({ type: 'EMOJI_MUTES_REVISION', revision: '2' });
      srcBeforeCommit = surface.querySelector('img').getAttribute('src');
    });
    mockDispatch.mockImplementation(previousDispatch);

    expect(srcBeforeCommit).toBeNull();
    expect(surface.innerHTML).not.toContain('/emoji/1f44d.svg');
    expect(surface.querySelector('p').textContent).toBe('Hello ◻');
    expect(view.getByTestId('webui')).toBe(surface);
    view.unmount();
  });

  it('scrubs visible emoji before React rerenders a stale revision and keeps the draft', async () => {
    const view = render(<Mastodon locale='en' />);
    await bootReady();
    const draft = view.getByTestId('compose-draft');
    fireEvent.change(draft, { target: { value: 'draft 👌 stays' } });
    const surface = view.getByTestId('webui');
    surface.insertAdjacentHTML('beforeend', '<p>Hello 👌</p><img class="emojione" alt="👌" title="👌" src="/emoji/1f44c.svg" srcset="/emoji/1f44c.svg 2x"><img src="/media/x.jpg" alt="photo 👌" srcset="/media/x.jpg 2x">');
    mockPhase = 'stale';
    mockDisplay = 'suppress';

    scrubVisibleEmojiIfUnverified();

    const emoji = surface.querySelector('img.emojione');
    expect(emoji).not.toBeNull();
    expect(emoji.hasAttribute('src')).toBe(false);
    expect(emoji.getAttribute('hidden')).toBe('');
    expect(surface.innerHTML).not.toContain('/emoji/1f44c.svg');
    expect(surface.querySelector('p').textContent).toBe('Hello ◻');
    expect(surface.querySelector('img[src="/media/x.jpg"]').getAttribute('alt')).toBe('photo ◻');
    expect(surface.querySelector('img[src="/media/x.jpg"]').getAttribute('srcset')).toBe('/media/x.jpg 2x');
    expect(draft.value).toBe('draft 👌 stays');
    expect(view.getByTestId('webui')).toBe(surface);

    mockPhase = 'stale';
    scrubVisibleEmojiIfUnverified();
    expect(surface.querySelector('img.emojione')).toBe(emoji);
    expect(surface.querySelector('img[src="/media/x.jpg"]')).not.toBeNull();
    view.unmount();
  });

  it('keeps the WebUI mounted and scrubs emoji when the GET fails', async () => {
    const view = render(<Mastodon locale='en' />);
    const surface = view.getByTestId('webui');
    const draft = view.getByTestId('compose-draft');
    fireEvent.change(draft, { target: { value: 'still drafting' } });
    await rejectBootstrap(new Error('offline'));
    surface.insertAdjacentHTML('beforeend', '<img class="emojione custom-emoji" alt=":blob:" src="https://cdn.example/secret.svg">');
    mockDisplay = 'suppress';
    mockPhase = 'error';
    scrubVisibleEmojiIfUnverified();

    expect(view.getByTestId('webui')).toBe(surface);
    expect(surface.querySelector('img.custom-emoji').hasAttribute('src')).toBe(false);
    expect(surface.innerHTML).not.toContain('secret.svg');
    expect(draft.value).toBe('still drafting');
    view.unmount();
  });
});
