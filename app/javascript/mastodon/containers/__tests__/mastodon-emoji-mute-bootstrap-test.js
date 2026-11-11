/* eslint-disable react/prop-types */

import { act, fireEvent, render } from '@testing-library/react';
import React from 'react';

let mockRequest;
let mockPhase = 'loading';
let mockMe = '1';
let mockToken = 'token';
const mockSubscribers = new Set();
const mockState = {
  getIn: path => {
    const key = path.join('.');
    if (key === 'emojiMutes.phase') return mockPhase;
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

jest.mock('mastodon/store/configureStore', () => ({
  __esModule: true,
  default: jest.fn(() => mockStore),
}));
jest.mock('mastodon/actions/store', () => ({ hydrateStore: () => ({ type: 'TEST_HYDRATE' }) }));
jest.mock('mastodon/actions/circles', () => ({ fetchCircles: () => ({ type: 'TEST_CIRCLES' }) }));
jest.mock('mastodon/features/emoji/emoji_picker_preferences', () => ({ preloadEmojiPickersIfNeeded: jest.fn() }));
jest.mock('mastodon/containers/mastodon_subscriptions', () => ({ startMastodonSubscriptions: (...args) => mockStartSubscriptions(...args) }));
jest.mock('mastodon/features/emoji/emoji_mute_store', () => ({ resetEmojiMuteSession: jest.fn() }));
jest.mock('mastodon/actions/emoji_mutes', () => ({
  EMOJI_MUTES_RESET: 'EMOJI_MUTES_RESET',
  invalidateEmojiMuteAsyncWork: jest.fn(),
  syncEmojiMutes: jest.fn(() => () => mockRequest.promise),
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
        <div data-testid='webui' aria-label='👍'>
          timeline <img alt='👍' src='/emoji/thumb.svg' />
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

// Mastodon creates its store during module evaluation. Load it only after
// the mock store and subscriber registry above have been initialized.
const Mastodon = require('../mastodon').default;

const deferred = () => {
  let resolve;
  let reject;
  const promise = new Promise((done, fail) => {
    resolve = done;
    reject = fail;
  });
  return { promise, resolve, reject };
};

const phaseChanged = next => {
  act(() => {
    mockPhase = next;
    mockSubscribers.forEach(listener => listener());
  });
};

const bootReady = async () => {
  await act(async () => {
    mockPhase = 'ready';
    mockRequest.resolve(null);
    await mockRequest.promise;
  });
};

describe('authenticated emoji mute bootstrap and revision gate', () => {
  beforeEach(() => {
    mockDispatch.mockClear();
    mockStartSubscriptions.mockClear();
    mockUiMounts.mockClear();
    mockUiUnmounts.mockClear();
    resetEmojiMuteSession.mockClear();
    mockSubscribers.clear();
    mockRequest = deferred();
    mockPhase = 'loading';
    mockMe = '1';
    mockToken = 'token';
  });

  it('does not mount the WebUI before an authoritative mute document is loaded', async () => {
    const view = render(<Mastodon locale='en' />);

    expect(view.queryByTestId('webui')).toBeNull();
    expect(view.getByText('Loading emoji mute settings…')).not.toBeNull();
    expect(mockStartSubscriptions).not.toHaveBeenCalled();
    expect(mockUiMounts).not.toHaveBeenCalled();

    await bootReady();

    expect(view.queryByTestId('webui')).not.toBeNull();
    expect(mockStartSubscriptions).toHaveBeenCalledTimes(1);
    view.unmount();
    expect(mockDispatch).toHaveBeenCalledWith({ type: 'EMOJI_MUTES_RESET' });
    expect(mockSubscribers.size).toBe(0);
  });

  it('unmounts visible images and aria labels during a stream revision gap', async () => {
    const view = render(<Mastodon locale='en' />);
    await bootReady();

    const ui = view.getByTestId('webui');
    const scroller = view.getByTestId('timeline-scroll');
    const draft = view.getByTestId('compose-draft');
    scroller.scrollTop = 237;
    fireEvent.change(draft, { target: { value: 'pending draft' } });
    draft.focus();
    expect(document.activeElement).toBe(draft);

    expect(ui.getAttribute('aria-label')).toBe('👍');
    expect(view.container.querySelector('img[src="/emoji/thumb.svg"]')).not.toBeNull();
    expect(mockUiMounts).toHaveBeenCalledTimes(1);
    phaseChanged('stale');

    // Detached DOM is absent from the displayed document, not CSS-hidden.
    expect(view.queryByTestId('webui')).toBeNull();
    expect(view.container.querySelector('img[src="/emoji/thumb.svg"]')).toBeNull();
    expect(view.container.innerHTML).not.toContain('👍');
    expect(view.getByText('Loading emoji mute settings…')).not.toBeNull();
    expect(mockUiUnmounts).not.toHaveBeenCalled();
    expect(mockStartSubscriptions).toHaveBeenCalledTimes(1);

    phaseChanged('ready');
    expect(view.getByTestId('webui')).toBe(ui);
    expect(view.getByTestId('timeline-scroll')).toBe(scroller);
    expect(scroller.scrollTop).toBe(237);
    expect(view.getByTestId('compose-draft').value).toBe('pending draft');
    expect(document.activeElement).toBe(draft);
    expect(mockUiMounts).toHaveBeenCalledTimes(1);
    expect(mockUiUnmounts).not.toHaveBeenCalled();
    expect(mockStartSubscriptions).toHaveBeenCalledTimes(1);
    view.unmount();
    expect(mockUiUnmounts).toHaveBeenCalledTimes(1);
  });

  it('keeps a failed update hidden and supports an explicit retry', async () => {
    const view = render(<Mastodon locale='en' />);
    await bootReady();

    const ui = view.getByTestId('webui');
    phaseChanged('stale');
    phaseChanged('error');
    expect(view.queryByTestId('webui')).toBeNull();
    expect(mockUiUnmounts).not.toHaveBeenCalled();
    expect(view.getByText(/could not be verified/)).not.toBeNull();

    mockRequest = deferred();
    fireEvent.click(view.getByText('Retry loading settings'));
    expect(view.queryByTestId('webui')).toBeNull();

    await bootReady();

    expect(view.getByTestId('webui')).toBe(ui);
    expect(mockUiMounts).toHaveBeenCalledTimes(1);
    view.unmount();
  });

  it('keeps the WebUI unmounted when the initial GET fails', async () => {
    const view = render(<Mastodon locale='en' />);

    await act(async () => {
      mockRequest.reject(new Error('offline'));
      try {
        await mockRequest.promise;
      } catch (_) {
        // The bootstrap handler owns the error.
      }
    });
    expect(view.queryByTestId('webui')).toBeNull();
    expect(view.getByText(/could not be verified/)).not.toBeNull();

    mockRequest = deferred();
    fireEvent.click(view.getByText('Retry loading settings'));
    await bootReady();

    expect(view.queryByTestId('webui')).not.toBeNull();
    view.unmount();
  });

  it('removes the old viewer DOM before clearing a changed session', async () => {
    const view = render(<Mastodon locale='en' />);
    await bootReady();

    act(() => {
      mockMe = 'another-account';
      mockSubscribers.forEach(listener => listener());
    });

    expect(view.queryByTestId('webui')).toBeNull();
    expect(view.container.querySelector('img')).toBeNull();
    expect(view.getByText(/Your account changed/)).not.toBeNull();
    expect(resetEmojiMuteSession).toHaveBeenCalled();
    expect(mockDispatch).toHaveBeenCalledWith({ type: 'EMOJI_MUTES_RESET' });
    view.unmount();
  });
});
