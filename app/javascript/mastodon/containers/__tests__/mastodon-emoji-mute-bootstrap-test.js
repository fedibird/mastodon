/* eslint-disable react/prop-types */

import { act, render } from '@testing-library/react';
import React from 'react';

let mockState;
let mockRequest;
const mockDispatch = jest.fn(action => {
  if (typeof action === 'function') {
    return action(mockDispatch, () => mockState);
  }
  return action;
});
const mockGetState = jest.fn(() => mockState);
const mockStore = { dispatch: mockDispatch, getState: mockGetState, subscribe: jest.fn(() => jest.fn()) };
const mockStartSubscriptions = jest.fn(() => jest.fn());

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
jest.mock('mastodon/features/ui', () => () => <div data-testid='webui'>timeline</div>);
jest.mock('mastodon/components/error_boundary', () => ({ children }) => <div>{children}</div>);
jest.mock('mastodon/features/embedded_rails_settings/navigation', () => ({
  settingsReturnScroll: () => null,
  settleSettingsReturnScroll: jest.fn(),
}));

import Mastodon from '../mastodon';

const deferred = () => {
  let resolve;
  let reject;
  const promise = new Promise((done, fail) => { resolve = done; reject = fail; });
  return { promise, resolve, reject };
};

describe('authenticated emoji mute bootstrap', () => {
  beforeEach(() => {
    mockDispatch.mockClear();
    mockStartSubscriptions.mockClear();
    mockRequest = deferred();
    mockState = { getIn: path => path.join('.') === 'emojiMutes.phase' ? 'loading' : undefined };
  });

  it('does not mount the WebUI before an authoritative mute document is loaded', async () => {
    const view = render(<Mastodon locale='en' />);

    expect(view.queryByTestId('webui')).toBeNull();
    expect(view.getByText('Loading emoji mute settings…')).not.toBeNull();
    expect(mockStartSubscriptions).not.toHaveBeenCalled();

    await act(async () => {
      mockState = { getIn: () => 'ready' };
      mockRequest.resolve(null);
      await mockRequest.promise;
    });

    expect(view.queryByTestId('webui')).not.toBeNull();
    expect(mockStartSubscriptions).toHaveBeenCalledTimes(1);
    view.unmount();
    expect(mockDispatch).toHaveBeenCalledWith({ type: 'EMOJI_MUTES_RESET' });
  });

  it('keeps the WebUI unmounted on failure and permits an explicit retry', async () => {
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
    const button = view.getByText('Retry loading settings');

    await act(async () => {
      button.click();
    });
    expect(view.queryByTestId('webui')).toBeNull();

    await act(async () => {
      mockState = { getIn: () => 'ready' };
      mockRequest.resolve([]);
      await mockRequest.promise;
    });
    expect(view.queryByTestId('webui')).not.toBeNull();
    view.unmount();
  });
});
