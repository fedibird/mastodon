/* eslint-disable react/prop-types */

import { fireEvent, render, screen } from '@testing-library/react';
import React from 'react';

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

jest.mock('mastodon/components/emoji', () => {
  const React = require('react');

  return function Emoji({ emoji, url, domain }) {
    return <img alt={emoji} data-url={url || ''} data-domain={domain || ''} />;
  };
});

import EmojiFilterBar from '../emoji_filter_bar';

const catalog = [
  { name: '🎉', custom: false, domain: null, count: 3 },
  {
    name: 'great',
    custom: true,
    domain: 'example.com',
    count: 2,
    url: 'https://cdn.example/great.png',
    static_url: 'https://cdn.example/great-static.png',
  },
];

describe('EmojiFilterBar', () => {
  it('shows selected emoji chips and removes one immediately', () => {
    const onChange = jest.fn();
    const onOpen = jest.fn();

    render(
      <EmojiFilterBar
        emojis={['🎉', 'great@example.com']}
        catalogItems={catalog}
        onChange={onChange}
        onOpen={onOpen}
      />,
    );

    expect(screen.getByRole('img', { name: '🎉' })).toBeInTheDocument();
    expect(screen.getByRole('img', { name: 'great' })).toHaveAttribute('data-url', 'https://cdn.example/great.png');
    expect(screen.getByRole('img', { name: 'great' })).toHaveAttribute('data-domain', 'example.com');

    fireEvent.click(screen.getByRole('button', { name: 'Remove 🎉 from emoji filter' }));

    expect(onChange).toHaveBeenCalledTimes(1);
    expect(onChange).toHaveBeenCalledWith(['great@example.com']);

    fireEvent.click(screen.getByRole('button', { name: 'Filter by emoji' }));

    expect(onOpen).toHaveBeenCalledTimes(1);
  });

  it('opens the picker from the empty filter button', () => {
    const onOpen = jest.fn();

    render(
      <EmojiFilterBar
        emojis={[]}
        catalogItems={catalog}
        expanded={false}
        onChange={jest.fn()}
        onOpen={onOpen}
      />,
    );

    const trigger = screen.getByRole('button', { name: 'Filter by emoji' });

    expect(trigger).toHaveAttribute('aria-expanded', 'false');
    expect(trigger).toHaveAttribute('aria-haspopup', 'dialog');

    fireEvent.click(trigger);

    expect(onOpen).toHaveBeenCalledTimes(1);
  });

  it('falls back to a text label when the selected emoji is not in the catalog', () => {
    render(
      <EmojiFilterBar
        emojis={['old@example.com']}
        catalogItems={catalog}
        onChange={jest.fn()}
        onOpen={jest.fn()}
      />,
    );

    expect(screen.getByText(':old:@example.com')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Remove :old:@example.com from emoji filter' })).toBeInTheDocument();
  });
});
