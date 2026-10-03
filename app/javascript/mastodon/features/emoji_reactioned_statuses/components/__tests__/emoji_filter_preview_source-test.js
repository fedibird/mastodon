/* eslint-disable react/prop-types */

import { act, fireEvent, render, screen } from '@testing-library/react';
import React from 'react';

jest.mock('mastodon/initial_state', () => ({
  ...jest.requireActual('mastodon/initial_state'),
  autoPlayEmoji: false,
}));

jest.mock('react-intl', () => {
  const interpolate = (defaultMessage, values) => {
    if (!values) {
      return defaultMessage;
    }

    return defaultMessage.split(/\{(\w+)\}/g).map((part, index) => (
      index % 2 === 1 ? values[part] : part
    )).join('');
  };
  const intl = {
    formatMessage: ({ defaultMessage }, values) => interpolate(defaultMessage, values),
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage, values }) => interpolate(defaultMessage, values),
  };
});

import EmojiReactionFilterPicker from '../emoji_filter_picker';

const catalog = [
  {
    name: 'achievement',
    custom: true,
    domain: 'example.com',
    count: 12,
    url: 'https://cdn.example/achievement.png',
    static_url: 'https://cdn.example/achievement-static.png',
  },
];

const pointer = (node, type, x, y) => {
  fireEvent[type](node, {
    pointerId: 1,
    pointerType: 'mouse',
    clientX: x,
    clientY: y,
    button: 0,
    bubbles: true,
    cancelable: true,
  });
};

const noop = () => {};

describe('emoji reaction filter preview source', () => {
  beforeEach(() => {
    jest.useFakeTimers();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  it('uses the original custom emoji url when autoplay is off', () => {
    render(
      <EmojiReactionFilterPicker
        catalogItems={catalog}
        appliedEmojis={[]}
        loaded
        autoFocus={false}
        onApply={noop}
        onClose={noop}
        onTogglePreferred={noop}
      />,
    );

    const tile = screen.getByRole('button', { name: ':achievement:@example.com' });

    pointer(tile, 'pointerDown', 12, 12);
    act(() => {
      jest.advanceTimersByTime(450);
    });

    const image = screen.getByTestId('emoji-reaction-filter-preview').querySelector('img');

    expect(image).toHaveAttribute('src', 'https://cdn.example/achievement.png');
    expect(image).toHaveAttribute('data-original', 'https://cdn.example/achievement.png');
    expect(image).toHaveAttribute('data-static', 'https://cdn.example/achievement-static.png');
  });
});
