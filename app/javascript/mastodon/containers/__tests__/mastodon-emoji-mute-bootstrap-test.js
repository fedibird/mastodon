/* eslint-disable react/prop-types */

import { act, fireEvent, render } from '@testing-library/react';
import React from 'react';
import { DropdownMenu } from 'mastodon/components/dropdown_menu';
import ModalRoot from 'mastodon/components/modal_root';

let mockRequest;
let mockPhase = 'loading';
let mockFailure = null;
let mockMe = '1';
let mockToken = 'token';
const mockSubscribers = new Set();
const mockState = {
  getIn: path => {
    const key = path.join('.');
    if (key === 'emojiMutes.phase') return mockPhase;
    if (key === 'emojiMutes.failure') return mockFailure;
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
import { getEmojiActionsOverlayRoot } from 'mastodon/features/emoji/emoji_actions/overlay_root';

// Mastodon creates its store during module evaluation. Load it only after
// the mock store and subscriber registry above have been initialized.
const Mastodon = require('../mastodon').default;
const { syncEmojiMutes } = require('mastodon/actions/emoji_mutes');

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

const phaseChanged = async next => {
  await act(async () => {
    mockPhase = next;
    mockSubscribers.forEach(listener => listener());
    // The privacy portal only reattaches in a microtask after the Redux
    // subscribers have finished rebuilding their safe display projections.
    await Promise.resolve();
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
    clock.now = 1_000_000;
    jest.spyOn(Date, 'now').mockImplementation(() => clock.now);
    mockDispatch.mockClear();
    syncEmojiMutes.mockClear();
    mockStartSubscriptions.mockClear();
    mockUiMounts.mockClear();
    mockUiUnmounts.mockClear();
    resetEmojiMuteSession.mockClear();
    mockSubscribers.clear();
    mockRequest = deferred();
    mockPhase = 'loading';
    mockFailure = null;
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

  it('does not mount the WebUI before an authoritative mute document is loaded', async () => {
    const view = render(<Mastodon locale='en' />);

    expect(view.queryByTestId('webui')).toBeNull();
    expect(syncEmojiMutes).toHaveBeenCalledWith({ bootstrap: true });
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
    const menuRoot = getEmojiActionsOverlayRoot();
    const menuImage = document.createElement('img');
    menuImage.src = '/private-menu-emoji.svg';
    menuImage.alt = 'hidden emoji';
    menuRoot.appendChild(menuImage);
    expect(menuImage.isConnected).toBe(true);
    scroller.scrollTop = 237;
    fireEvent.change(draft, { target: { value: 'pending draft' } });
    draft.focus();
    expect(document.activeElement).toBe(draft);

    expect(ui.getAttribute('aria-label')).toBe('👍');
    expect(view.container.querySelector('img[src="/emoji/thumb.svg"]')).not.toBeNull();
    expect(mockUiMounts).toHaveBeenCalledTimes(1);
    await phaseChanged('stale');

    // Detached DOM is absent from the displayed document, not CSS-hidden.
    expect(view.queryByTestId('webui')).toBeNull();
    expect(view.container.querySelector('img[src="/emoji/thumb.svg"]')).toBeNull();
    expect(view.container.innerHTML).not.toContain('👍');
    expect(document.querySelector('img[src="/private-menu-emoji.svg"]')).toBeNull();
    expect(getEmojiActionsOverlayRoot()).toBe(menuRoot);
    expect(view.getByText('Loading emoji mute settings…')).not.toBeNull();
    expect(mockUiUnmounts).not.toHaveBeenCalled();
    expect(mockStartSubscriptions).toHaveBeenCalledTimes(1);

    await phaseChanged('ready');
    expect(view.getByTestId('webui')).toBe(ui);
    expect(view.getByTestId('timeline-scroll')).toBe(scroller);
    expect(document.querySelector('img[src="/private-menu-emoji.svg"]')).toBe(menuImage);
    expect(scroller.scrollTop).toBe(237);
    expect(view.getByTestId('compose-draft').value).toBe('pending draft');
    expect(document.activeElement).toBe(draft);
    expect(mockUiMounts).toHaveBeenCalledTimes(1);
    expect(mockUiUnmounts).not.toHaveBeenCalled();
    expect(mockStartSubscriptions).toHaveBeenCalledTimes(1);
    view.unmount();
    expect(mockUiUnmounts).toHaveBeenCalledTimes(1);
  });

  it('never reattaches an earlier ready transition after another revision arrives', async () => {
    const view = render(<Mastodon locale='en' />);
    await bootReady();

    await phaseChanged('stale');
    await act(async () => {
      mockPhase = 'ready';
      mockSubscribers.forEach(listener => listener());
      mockPhase = 'stale';
      mockSubscribers.forEach(listener => listener());
      await Promise.resolve();
    });

    expect(view.queryByTestId('webui')).toBeNull();
    expect(view.container.querySelector('img')).toBeNull();
    expect(mockUiMounts).toHaveBeenCalledTimes(1);
    expect(mockUiUnmounts).not.toHaveBeenCalled();

    await phaseChanged('ready');
    expect(view.queryByTestId('webui')).not.toBeNull();
    expect(mockUiMounts).toHaveBeenCalledTimes(1);
    view.unmount();
  });

  it('keeps a failed update hidden and supports an explicit retry', async () => {
    const view = render(<Mastodon locale='en' />);
    await bootReady();

    const ui = view.getByTestId('webui');
    await phaseChanged('stale');
    await phaseChanged('error');
    expect(view.queryByTestId('webui')).toBeNull();
    expect(mockUiUnmounts).not.toHaveBeenCalled();
    expect(view.getByText(/could not be verified/)).not.toBeNull();

    mockRequest = deferred();
    allowRetry();
    fireEvent.click(view.getByText('Retry loading settings'));
    expect(syncEmojiMutes).toHaveBeenLastCalledWith({ bootstrap: false });
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
    allowRetry();
    fireEvent.click(view.getByText('Retry loading settings'));
    expect(syncEmojiMutes).toHaveBeenLastCalledWith({ bootstrap: true });
    await bootReady();

    expect(view.queryByTestId('webui')).not.toBeNull();
    view.unmount();
  });

  it('keeps Tab on the retry control while an open menu and modal are detached', async () => {
    const view = render(<Mastodon locale='en' />);
    await bootReady();

    const portal = document.querySelector('.emoji-mutes-privacy-portal');
    const menuHolder = document.createElement('div');
    const modalHolder = document.createElement('div');
    portal.appendChild(menuHolder);
    portal.appendChild(modalHolder);
    function closeMenu() {}
    function chooseMenuItem() {}
    function closeModal() {}
    const menu = render(
      <DropdownMenu items={[{ text: 'Hide emoji' }]} onClose={closeMenu} onItemClick={chooseMenuItem} />,
      { container: menuHolder },
    );
    const modal = render(
      <ModalRoot onClose={closeModal}><button type='button'>Inside modal</button></ModalRoot>,
      { container: modalHolder },
    );
    menu.getByText('Hide emoji').focus();

    await phaseChanged('error');

    const retry = view.getByRole('button', { name: 'Retry loading settings' });
    expect(menuHolder.isConnected).toBe(false);
    expect(modalHolder.isConnected).toBe(false);
    expect(document.body.contains(retry)).toBe(true);

    const menuTab = new KeyboardEvent('keydown', { key: 'Tab', bubbles: true, cancelable: true });
    document.dispatchEvent(menuTab);
    const modalTab = new KeyboardEvent('keydown', { key: 'Tab', bubbles: true, cancelable: true });
    window.dispatchEvent(modalTab);
    expect(menuTab.defaultPrevented).toBe(false);
    expect(modalTab.defaultPrevented).toBe(false);

    retry.focus();
    expect(document.activeElement).toBe(retry);

    await phaseChanged('ready');
    expect(menuHolder.isConnected).toBe(true);
    expect(modalHolder.isConnected).toBe(true);

    const restoredModalTab = new KeyboardEvent('keydown', { key: 'Tab', bubbles: true, cancelable: true });
    window.dispatchEvent(restoredModalTab);
    expect(restoredModalTab.defaultPrevented).toBe(true);
    expect(document.activeElement).toBe(modal.getByText('Inside modal'));

    modal.unmount();
    const restoredTab = new KeyboardEvent('keydown', { key: 'Tab', bubbles: true, cancelable: true });
    document.dispatchEvent(restoredTab);
    expect(restoredTab.defaultPrevented).toBe(true);
    expect(document.activeElement).toBe(menu.getByText('Hide emoji'));

    menu.unmount();
    view.unmount();
  });

  it('sends an expired session to sign-in and a forbidden token to an explanation', async () => {
    const unauthorized = render(<Mastodon locale='en' />);
    const denied = Object.assign(new Error('unauthorized'), { response: { status: 401 } });
    await rejectBootstrap(denied);

    expect(unauthorized.queryByTestId('webui')).toBeNull();
    expect(unauthorized.getByText(/session expired/i)).not.toBeNull();
    expect(unauthorized.getByText('Reload and sign in')).not.toBeNull();
    expect(unauthorized.queryByText('Retry loading settings')).toBeNull();
    unauthorized.unmount();

    mockRequest = deferred();
    const forbiddenView = render(<Mastodon locale='en' />);
    await rejectBootstrap(Object.assign(new Error('forbidden'), { response: { status: 403 } }));

    expect(forbiddenView.getByText(/cannot read emoji mute settings/i)).not.toBeNull();
    expect(forbiddenView.queryByText('Retry loading settings')).toBeNull();
    expect(forbiddenView.queryByText('Reload and sign in')).toBeNull();
    forbiddenView.unmount();
  });

  it('shows the sign-in gate when a ready session is rejected by the store', async () => {
    const view = render(<Mastodon locale='en' />);
    await bootReady();
    const ui = view.getByTestId('webui');

    mockFailure = 'unauthorized';
    await phaseChanged('error');
    await phaseChanged('error');

    expect(view.queryByTestId('webui')).toBeNull();
    expect(document.querySelector('.emoji-mutes-privacy-portal')).toBeNull();
    expect(view.getByText(/session expired/i)).not.toBeNull();
    expect(view.queryByText('Retry loading settings')).toBeNull();
    expect(mockUiUnmounts).not.toHaveBeenCalled();

    mockFailure = null;
    await phaseChanged('ready');
    expect(view.getByTestId('webui')).toBe(ui);
    expect(mockUiMounts).toHaveBeenCalledTimes(1);
    view.unmount();
  });

  it('ignores a retry click until the quiet period has elapsed, then allows one', async () => {
    const view = render(<Mastodon locale='en' />);
    await rejectBootstrap(new Error('offline'));

    const callsBefore = mockDispatch.mock.calls.filter(call => typeof call[0] === 'function').length;
    fireEvent.click(view.getByText('Retry loading settings'));
    expect(mockDispatch.mock.calls.filter(call => typeof call[0] === 'function').length).toBe(callsBefore);

    allowRetry();
    mockRequest = deferred();
    fireEvent.click(view.getByText('Retry loading settings'));
    expect(mockDispatch.mock.calls.filter(call => typeof call[0] === 'function').length).toBe(callsBefore + 1);
    expect(view.queryByText('Retry loading settings')).toBeNull();
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
