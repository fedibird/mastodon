/* eslint-disable react/prop-types */

import { fireEvent, render } from '@testing-library/react';
import React from 'react';
import { Provider } from 'react-redux';

jest.mock('mastodon/actions/emoji_mutes', () => ({
  retryEmojiMuteLoad: jest.fn(() => ({ type: 'EMOJI_MUTES_LOAD' })),
}));

jest.mock('react-intl', () => ({
  FormattedMessage: ({ defaultMessage }) => <span>{defaultMessage}</span>,
}));

import { retryEmojiMuteLoad } from 'mastodon/actions/emoji_mutes';
import StandaloneEmojiMuteRetry from '../standalone_emoji_mute_retry';

const storeFor = (phase, availability) => ({
  getState: () => ({
    getIn: path => {
      const key = path.join('.');
      if (key === 'emojiMutes.phase') {
        return phase;
      }
      if (key === 'emojiMutes.availability') {
        return availability;
      }
      return undefined;
    },
  }),
  dispatch: jest.fn(action => action),
  subscribe: jest.fn(() => jest.fn()),
});

describe('standalone emoji mute retry', () => {
  beforeEach(() => {
    retryEmojiMuteLoad.mockClear();
  });

  it('offers a retry when the rules load failed and leaves the composer usable', () => {
    const store = storeFor('error', 'enabled');
    const view = render(
      <Provider store={store}>
        <React.Fragment>
          <StandaloneEmojiMuteRetry />
          <textarea data-testid='compose' defaultValue='hello' />
        </React.Fragment>
      </Provider>,
    );

    expect(view.getByText(/You can keep composing/)).not.toBeNull();
    fireEvent.click(view.getByText('Retry loading settings'));
    expect(retryEmojiMuteLoad).toHaveBeenCalledTimes(1);
    expect(view.getByTestId('compose').value).toBe('hello');
  });

  it('stays quiet when the rules load succeeded', () => {
    const view = render(
      <Provider store={storeFor('ready', 'enabled')}>
        <StandaloneEmojiMuteRetry />
      </Provider>,
    );

    expect(view.queryByText('Retry loading settings')).toBeNull();
  });
});
