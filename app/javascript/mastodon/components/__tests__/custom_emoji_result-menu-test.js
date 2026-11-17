/**
 * @jest-environment jsdom
 */

import React from 'react';
import { fireEvent, render } from '@testing-library/react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';
import { fromJS } from 'immutable';
import { resetEmojiActionsBusForTests, setEmojiActionsListener } from 'mastodon/features/emoji/emoji_actions/bus';
import CustomEmojiResult from '../custom_emoji_result';

jest.mock('mastodon/initial_state', () => ({
  me: 'viewer',
  autoPlayEmoji: false,
}));

jest.mock('react-intl', () => {
  const ReactMock = require('react');
  const intl = { formatMessage: message => message.defaultMessage || message.id };
  return {
    defineMessages: messages => messages,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    FormattedMessage: ({ defaultMessage }) => <ReactMock.Fragment>{defaultMessage}</ReactMock.Fragment>,
  };
});

describe('custom emoji search result actions', () => {
  afterEach(() => {
    resetEmojiActionsBusForTests();
  });

  it('opens the common actions menu on click rather than navigating directly', () => {
    const state = fromJS({
      custom_emojis_detail: {
        wide: { shortcode: 'wide', domain: null, url: '/wide.gif', static_url: '/wide.png', alternate_name: 'Wide emoji' },
      },
    });
    const store = createStore((value = state) => value);
    const opened = jest.fn();
    const stop = setEmojiActionsListener(opened);
    const { container } = render(
      <Provider store={store}>
        <CustomEmojiResult shortcode_with_domain='wide' />
      </Provider>,
    );

    const emoji = container.querySelector('img.custom-emoji');
    expect(emoji).not.toBeNull();
    expect(emoji.dataset.emojiActions).toBe('1');
    fireEvent.click(emoji);
    expect(opened).toHaveBeenCalledTimes(1);
    expect(opened).toHaveBeenCalledWith(expect.objectContaining({
      source: 'inline_emoji_search',
      reference: { kind: 'custom', scope: 'local', shortcode: 'wide' },
    }));
    stop();
  });
});
