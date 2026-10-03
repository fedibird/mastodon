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

import EmojiReactionFilterPicker from '../emoji_filter_picker';

const catalog = [
  { name: '🎉', custom: false, domain: null, count: 183 },
  { name: '👍', custom: false, domain: null, count: 121 },
  { name: '❤️', custom: false, domain: null, count: 97 },
  {
    name: 'great',
    custom: true,
    domain: null,
    count: 43,
    url: 'https://cdn.example/great.png',
    static_url: 'https://cdn.example/great-static.png',
    alternate_name: 'すごい',
    ruby: 'グレート',
    aliases: ['awesome'],
  },
  {
    name: 'achievement',
    custom: true,
    domain: 'example.com',
    count: 12,
    url: 'https://cdn.example/achievement.png',
    static_url: 'https://cdn.example/achievement-static.png',
    alternate_name: '達成',
    ruby: 'たっせい',
    aliases: ['goal', 'remote-alias'],
  },
];

const renderPicker = (props = {}) => {
  const onApply = jest.fn();
  const onClose = jest.fn();

  render(
    <EmojiReactionFilterPicker
      catalogItems={catalog}
      appliedEmojis={[]}
      loaded
      onApply={onApply}
      onClose={onClose}
      autoFocus={false}
      {...props}
    />,
  );

  return { onApply, onClose };
};

const tileLabels = () => screen.getAllByRole('button')
  .filter(button => button.hasAttribute('aria-pressed'))
  .map(button => button.getAttribute('aria-label'));

describe('EmojiReactionFilterPicker', () => {
  it('keeps catalog order and shows each count', () => {
    renderPicker();

    expect(tileLabels()).toEqual(['🎉', '👍', '❤️', ':great:', ':achievement:@example.com']);
    expect(screen.getByRole('button', { name: '🎉' })).toHaveTextContent('183');
    expect(screen.getByRole('button', { name: ':achievement:@example.com' })).toHaveTextContent('12');
  });

  it('appends multiple selections and applies them once', () => {
    const { onApply } = renderPicker({ appliedEmojis: ['🎉'] });

    fireEvent.click(screen.getByRole('button', { name: '👍' }));
    fireEvent.click(screen.getByRole('button', { name: '❤️' }));

    expect(onApply).not.toHaveBeenCalled();
    expect(screen.getByRole('button', { name: '👍' })).toHaveAttribute('aria-pressed', 'true');
    expect(screen.getByText('3 emojis selected')).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: 'Apply' }));

    expect(onApply).toHaveBeenCalledTimes(1);
    expect(onApply).toHaveBeenCalledWith(['🎉', '👍', '❤️']);
  });

  it('removes a selected emoji from the draft', () => {
    const { onApply } = renderPicker({ appliedEmojis: ['🎉', '👍'] });

    fireEvent.click(screen.getByRole('button', { name: '👍' }));

    expect(screen.getByRole('button', { name: '👍' })).toHaveAttribute('aria-pressed', 'false');

    fireEvent.click(screen.getByRole('button', { name: 'Apply' }));

    expect(onApply).toHaveBeenCalledWith(['🎉']);
  });

  it('does not apply a cancelled draft', () => {
    const { onApply, onClose } = renderPicker({ appliedEmojis: ['🎉'] });

    fireEvent.click(screen.getByRole('button', { name: '👍' }));
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));

    expect(onApply).not.toHaveBeenCalled();
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('clears the draft and applies an empty filter', () => {
    const { onApply } = renderPicker({ appliedEmojis: ['🎉', '👍'] });

    fireEvent.click(screen.getByRole('button', { name: 'Clear all' }));

    expect(screen.getByText('None selected')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '🎉' })).toHaveAttribute('aria-pressed', 'false');
    expect(onApply).not.toHaveBeenCalled();

    fireEvent.click(screen.getByRole('button', { name: 'Apply' }));

    expect(onApply).toHaveBeenCalledWith([]);
  });

  it('keeps a selected emoji that is no longer in the catalog', () => {
    const { onApply } = renderPicker({ appliedEmojis: ['old@example.com'] });
    const missing = screen.getByRole('button', { name: ':old:@example.com' });

    expect(screen.getByText('Emoji not currently used')).toBeInTheDocument();
    expect(missing).toHaveAttribute('aria-pressed', 'true');
    expect(missing).toHaveTextContent('0');
    expect(screen.getByRole('button', { name: 'Apply' })).toBeDisabled();

    fireEvent.click(screen.getByRole('button', { name: 'Apply' }));
    expect(onApply).not.toHaveBeenCalled();

    fireEvent.click(missing);
    fireEvent.click(screen.getByRole('button', { name: 'Apply' }));

    expect(onApply).toHaveBeenCalledWith([]);
  });

  it('keeps an untouched missing emoji when another emoji is applied', () => {
    const { onApply } = renderPicker({ appliedEmojis: ['old@example.com'] });

    fireEvent.click(screen.getByRole('button', { name: '🎉' }));
    fireEvent.click(screen.getByRole('button', { name: 'Apply' }));

    expect(onApply).toHaveBeenCalledWith(['old@example.com', '🎉']);
  });

  it('renders a remote custom emoji with its image, label, and filter value', () => {
    const { onApply } = renderPicker();
    const tile = screen.getByRole('button', { name: ':achievement:@example.com' });

    expect(tile.querySelector('img')).toHaveAttribute('data-url', 'https://cdn.example/achievement.png');
    expect(tile.querySelector('img')).toHaveAttribute('data-domain', 'example.com');
    expect(screen.getByRole('button', { name: ':great:' })).toBeInTheDocument();

    fireEvent.click(tile);
    fireEvent.click(screen.getByRole('button', { name: 'Apply' }));

    expect(onApply).toHaveBeenCalledWith(['achievement@example.com']);
  });

  it('filters by alias, ruby, and domain without reordering matches', () => {
    renderPicker();
    const search = screen.getByRole('searchbox', { name: 'Search emoji you have used' });

    fireEvent.change(search, { target: { value: 'remote-alias' } });
    expect(tileLabels()).toEqual([':achievement:@example.com']);

    fireEvent.change(search, { target: { value: 'たっせい' } });
    expect(tileLabels()).toEqual([':achievement:@example.com']);

    fireEvent.change(search, { target: { value: 'example.com' } });
    expect(tileLabels()).toEqual([':achievement:@example.com']);

    fireEvent.change(search, { target: { value: 'すごい' } });
    expect(tileLabels()).toEqual([':great:']);

    fireEvent.change(search, { target: { value: 'a' } });
    expect(tileLabels()).toEqual([':great:', ':achievement:@example.com']);
  });

  it('shows a message when nothing matches', () => {
    renderPicker();

    fireEvent.change(screen.getByRole('searchbox'), { target: { value: 'zzzz-no-match' } });

    expect(screen.getByText('No matching reaction emoji')).toBeInTheDocument();
    expect(tileLabels()).toEqual([]);
  });

  it('shows an empty catalog message and disables apply', () => {
    renderPicker({ catalogItems: [], appliedEmojis: [], loaded: true });

    expect(screen.getByText('No reaction emoji in use yet')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Apply' })).toBeDisabled();
  });

  it('shows a loading indicator before the catalog arrives', () => {
    renderPicker({ catalogItems: [], appliedEmojis: ['🎉'], loaded: false, isLoading: true });

    expect(screen.getByRole('progressbar')).toBeInTheDocument();
    expect(screen.queryByText('No reaction emoji in use yet')).not.toBeInTheDocument();
    expect(screen.queryByText('Emoji not currently used')).not.toBeInTheDocument();
  });

  it('closes on escape without applying', () => {
    const { onApply, onClose } = renderPicker({ appliedEmojis: ['🎉'] });

    fireEvent.keyDown(screen.getByRole('dialog'), { key: 'Escape' });

    expect(onClose).toHaveBeenCalledTimes(1);
    expect(onApply).not.toHaveBeenCalled();
  });
});
