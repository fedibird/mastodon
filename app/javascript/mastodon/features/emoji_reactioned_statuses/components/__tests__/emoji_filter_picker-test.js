/* eslint-disable react/prop-types */

import { act, fireEvent, render, screen } from '@testing-library/react';
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
  const onTogglePreferred = jest.fn();

  render(
    <EmojiReactionFilterPicker
      catalogItems={catalog}
      appliedEmojis={[]}
      loaded
      onApply={onApply}
      onClose={onClose}
      onTogglePreferred={onTogglePreferred}
      autoFocus={false}
      {...props}
    />,
  );

  return { onApply, onClose, onTogglePreferred: props.onTogglePreferred || onTogglePreferred };
};

const tileLabels = () => {
  const tiles = screen.queryAllByRole('button')
    .filter(button => button.classList.contains('emoji-reaction-filter-picker__tile'));

  return tiles.map(button => button.getAttribute('aria-label'));
};

const labelsInSection = (name) => {
  const heading = screen.getByRole('heading', { name });

  return Array.from(heading.parentElement.querySelectorAll('.emoji-reaction-filter-picker__tile'))
    .map(button => button.getAttribute('aria-label'));
};

const enterEdit = () => {
  fireEvent.click(screen.getByRole('button', { name: 'Edit pinned' }));
};

const dragOverlay = () => document.querySelector('.emoji-reaction-filter-picker__drag-overlay');

const expectFloatingOverlay = (source) => {
  const overlay = dragOverlay();

  expect(overlay).not.toBeNull();
  expect(overlay.parentElement).toBe(document.body);
  expect(overlay).toHaveAttribute('aria-hidden', 'true');
  expect(overlay.closest('.emoji-reaction-filter-picker__body')).toBeNull();
  expect(overlay.closest('.emoji-reaction-filter-picker__pinned')).toBeNull();
  expect(source.isConnected).toBe(true);
  expect(source.parentElement).toHaveClass('is-drag-source');
  expect(source).not.toHaveClass('is-floating');
};

const pinnedFlow = () => Array.from(document.querySelectorAll('.emoji-reaction-filter-picker__group--pinned .emoji-reaction-filter-picker__grid > *'))
  .filter(node => !node.classList.contains('is-drag-source'))
  .map(node => node.getAttribute('data-pin-value') || (node.hasAttribute('data-placeholder') ? 'placeholder' : 'other'));

const clickTile = (tile, detail) => {
  fireEvent.click(tile, { detail });
};

const starButtons = () => screen.queryAllByRole('button').filter(button => (
  button.classList.contains('emoji-reaction-filter-picker__preferred-toggle')
));

const installPointerEvent = () => {
  if (typeof window.PointerEvent === 'function') {
    return;
  }

  function PointerEventPolyfill(type, props) {
    const init = props || {};
    const event = new window.MouseEvent(type, init);
    const pointerId = init.pointerId === undefined || init.pointerId === null ? 1 : init.pointerId;

    Object.defineProperty(event, 'pointerId', { value: pointerId });
    Object.defineProperty(event, 'pointerType', { value: init.pointerType || 'mouse' });

    return event;
  }

  window.PointerEvent = PointerEventPolyfill;
};

const pointer = (node, type, x, y, pointerType = 'mouse') => {
  fireEvent[type](node, {
    pointerId: 1,
    pointerType,
    clientX: x,
    clientY: y,
    button: 0,
    bubbles: true,
    cancelable: true,
  });
};

const rect = (left, top, width, height) => ({
  x: left,
  y: top,
  left,
  top,
  right: left + width,
  bottom: top + height,
  width,
  height,
  toJSON() {
    return this;
  },
});

const installLayout = (itemRects, geometry = {}) => {
  const viewport = geometry.viewport || rect(0, 0, 320, 180);
  const section = geometry.section || rect(0, 0, 320, 180);
  const original = HTMLElement.prototype.getBoundingClientRect;

  HTMLElement.prototype.getBoundingClientRect = function () {
    if (this.classList && this.classList.contains('emoji-reaction-filter-picker__pinned')) {
      return viewport;
    }

    if (this.dataset && this.dataset.dropZone) {
      return section;
    }

    const value = this.dataset && this.dataset.pinValue;

    if (value && itemRects[value]) {
      return itemRects[value];
    }

    return original.apply(this, arguments);
  };

  return () => {
    HTMLElement.prototype.getBoundingClientRect = original;
  };
};

describe('EmojiReactionFilterPicker', () => {
  beforeAll(() => {
    installPointerEvent();
  });

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

  it('shows preferred emoji first and does not repeat them below', () => {
    renderPicker({
      catalogItems: [
        { name: '🎉', custom: false, domain: null, count: 100 },
        { name: '👍', custom: false, domain: null, count: 50 },
        { name: '❤️', custom: false, domain: null, count: 25 },
      ],
      preferredEmojis: ['❤️', '🎉'],
    });

    expect(labelsInSection('Pinned')).toEqual(['❤️', '🎉']);
    expect(labelsInSection('Frequently used')).toEqual(['👍']);
    expect(tileLabels()).toEqual(['❤️', '🎉', '👍']);
    expect(starButtons()).toHaveLength(0);
    expect(screen.getByRole('button', { name: 'Edit pinned' })).toHaveAttribute('aria-pressed', 'false');

    enterEdit();

    expect(screen.getByRole('button', { name: 'Unpin ❤️' })).toHaveAttribute('aria-pressed', 'true');
    expect(screen.getByRole('button', { name: 'Pin 👍' })).toHaveAttribute('aria-pressed', 'false');
  });

  it('pins an emoji without selecting it or applying the filter', () => {
    const onTogglePreferred = jest.fn();
    const { onApply } = renderPicker({
      appliedEmojis: ['🎉'],
      preferredEmojis: ['❤️', '🎉'],
      onTogglePreferred,
    });

    enterEdit();
    fireEvent.click(screen.getByRole('button', { name: 'Pin 👍' }));

    expect(onTogglePreferred).toHaveBeenCalledWith(['❤️', '🎉', '👍']);
    expect(onApply).not.toHaveBeenCalled();
    expect(screen.getByRole('button', { name: '👍' })).toHaveAttribute('aria-pressed', 'false');
    expect(screen.getByRole('button', { name: '🎉' })).toHaveAttribute('aria-pressed', 'true');
  });

  it('unpins an emoji and keeps the remaining preferred order', () => {
    const onTogglePreferred = jest.fn();

    renderPicker({
      preferredEmojis: ['❤️', '🎉', '👍'],
      onTogglePreferred,
    });

    enterEdit();
    fireEvent.click(screen.getByRole('button', { name: 'Unpin 🎉' }));

    expect(onTogglePreferred).toHaveBeenCalledWith(['❤️', '👍']);
  });

  it('does not select or pin an emoji when its tile is clicked while editing', () => {
    const onTogglePreferred = jest.fn();

    renderPicker({ preferredEmojis: ['❤️'], onTogglePreferred });

    enterEdit();
    fireEvent.click(screen.getByRole('button', { name: '👍' }));

    expect(onTogglePreferred).not.toHaveBeenCalled();
    expect(screen.getByRole('button', { name: '👍' })).toHaveAttribute('aria-pressed', 'false');
    expect(screen.getByRole('button', { name: 'Pin 👍' })).toHaveAttribute('aria-pressed', 'false');
  });

  it('clears only the filter draft', () => {
    const onTogglePreferred = jest.fn();

    renderPicker({
      appliedEmojis: ['🎉', '👍'],
      preferredEmojis: ['❤️'],
      onTogglePreferred,
    });

    enterEdit();
    fireEvent.click(screen.getByRole('button', { name: 'Clear all' }));

    expect(screen.getByRole('button', { name: '🎉' })).toHaveAttribute('aria-pressed', 'false');
    expect(screen.getByRole('button', { name: 'Unpin ❤️' })).toHaveAttribute('aria-pressed', 'true');
    expect(onTogglePreferred).not.toHaveBeenCalled();
  });

  it('keeps a preferred change when the filter draft is cancelled', () => {
    const onTogglePreferred = jest.fn();
    const { onApply, onClose } = renderPicker({
      appliedEmojis: ['🎉'],
      preferredEmojis: ['❤️'],
      onTogglePreferred,
    });

    fireEvent.click(screen.getByRole('button', { name: '👍' }));
    enterEdit();
    fireEvent.click(screen.getByRole('button', { name: 'Pin 👍' }));
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));

    expect(onTogglePreferred).toHaveBeenCalledWith(['❤️', '👍']);
    expect(onApply).not.toHaveBeenCalled();
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('keeps a preferred emoji that has left the catalog', () => {
    const onTogglePreferred = jest.fn();

    renderPicker({
      catalogItems: [
        { name: '🎉', custom: false, domain: null, count: 4 },
        { name: '👍', custom: false, domain: null, count: 2 },
      ],
      preferredEmojis: ['old@example.com', '🎉'],
      onTogglePreferred,
    });

    expect(labelsInSection('Pinned')).toEqual([':old:@example.com', '🎉']);
    expect(labelsInSection('Frequently used')).toEqual(['👍']);

    const missing = screen.getByRole('button', { name: ':old:@example.com' });

    expect(missing).toHaveTextContent('0');
    expect(missing.parentElement).toHaveTextContent('Emoji not currently used');
    expect(screen.queryByText('Emoji not currently used', { selector: 'p' })).not.toBeInTheDocument();

    enterEdit();
    expect(screen.getByRole('button', { name: 'Unpin :old:@example.com' })).toHaveAttribute('aria-pressed', 'true');

    fireEvent.click(screen.getByRole('button', { name: 'Unpin :old:@example.com' }));

    expect(onTogglePreferred).toHaveBeenCalledWith(['🎉']);
  });

  it('shows a selected preferred emoji that is missing from the catalog only once', () => {
    renderPicker({
      catalogItems: [],
      appliedEmojis: ['old@example.com'],
      preferredEmojis: ['old@example.com'],
      loaded: true,
    });

    expect(tileLabels()).toEqual([':old:@example.com']);
    expect(screen.getAllByText('Emoji not currently used')).toHaveLength(1);
    expect(screen.queryByRole('heading', { name: 'Frequently used' })).not.toBeInTheDocument();
  });

  it('filters preferred and remaining emoji without reordering either section', () => {
    renderPicker({
      catalogItems: [
        { name: '🎉', custom: false, domain: null, count: 3 },
        {
          name: 'achievement',
          custom: true,
          domain: 'example.com',
          count: 2,
          url: 'https://cdn.example/achievement.png',
        },
        { name: 'great', custom: true, domain: null, count: 1 },
        {
          name: 'another',
          custom: true,
          domain: 'example.net',
          count: 1,
          url: 'https://cdn.example/another.png',
        },
      ],
      preferredEmojis: ['achievement@example.com', 'great', 'old@example.com'],
    });

    fireEvent.change(screen.getByRole('searchbox'), { target: { value: 'example' } });

    expect(labelsInSection('Pinned')).toEqual([':achievement:@example.com', ':old:@example.com']);
    expect(labelsInSection('Frequently used')).toEqual([':another:@example.net']);
    expect(tileLabels()).toEqual([':achievement:@example.com', ':old:@example.com', ':another:@example.net']);
  });

  it('finds a custom emoji from romaji shortcode when ruby is missing', () => {
    renderPicker({
      catalogItems: [
        { name: '🎉', custom: false, domain: null, count: 4 },
        { name: 'kore', custom: true, domain: null, count: 2, url: 'https://cdn.example/kore.png' },
        { name: 'kokoro', custom: true, domain: null, count: 1, url: 'https://cdn.example/kokoro.png' },
      ],
    });

    fireEvent.change(screen.getByRole('searchbox'), { target: { value: 'これ' } });

    expect(tileLabels()).toEqual([':kore:']);
  });

  it('hides star buttons until pinned editing is open', () => {
    renderPicker({ preferredEmojis: [] });

    expect(starButtons()).toHaveLength(0);
    expect(screen.queryByRole('heading', { name: 'Pinned' })).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Edit pinned' })).toHaveAttribute('aria-pressed', 'false');

    enterEdit();

    expect(screen.getByRole('button', { name: 'Done' })).toHaveAttribute('aria-pressed', 'true');
    expect(screen.getByRole('heading', { name: 'Pinned' })).toBeInTheDocument();
    expect(screen.getByText('Drag here to pin')).toBeInTheDocument();
    expect(document.querySelector('.emoji-reaction-filter-picker')).toHaveClass('is-editing-pinned');
    expect(screen.getByText('Drag here to pin').closest('.emoji-reaction-filter-picker__pinned')).not.toBeNull();
    expect(starButtons().length).toBeGreaterThan(0);
    expect(screen.getByRole('heading', { name: 'Pinned' }).closest('.emoji-reaction-filter-picker__body')).toBeNull();
    expect(screen.getByRole('heading', { name: 'Pinned' }).closest('.emoji-reaction-filter-picker__pinned')).not.toBeNull();

    fireEvent.click(screen.getByRole('button', { name: 'Done' }));

    expect(starButtons()).toHaveLength(0);
    expect(screen.queryByText('Drag here to pin')).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Edit pinned' })).toHaveAttribute('aria-pressed', 'false');
  });

  it('keeps pinned emoji outside the scrolling list while editing', () => {
    renderPicker({ preferredEmojis: ['❤️', '🎉'] });

    const pinned = screen.getByRole('heading', { name: 'Pinned' }).closest('section');

    expect(pinned.closest('.emoji-reaction-filter-picker__body')).not.toBeNull();

    enterEdit();

    const fixed = screen.getByRole('heading', { name: 'Pinned' }).closest('section');

    expect(document.querySelector('.emoji-reaction-filter-picker')).toHaveClass('is-editing-pinned');
    expect(fixed.closest('.emoji-reaction-filter-picker__body')).toBeNull();
    expect(fixed.closest('.emoji-reaction-filter-picker__pinned')).not.toBeNull();
    expect(labelsInSection('Frequently used')).toEqual(['👍', ':great:', ':achievement:@example.com']);
  });

  it('pins with the star without changing the filter draft', () => {
    const onTogglePreferred = jest.fn();
    const { onApply } = renderPicker({
      appliedEmojis: ['🎉', '👍'],
      preferredEmojis: ['🎉'],
      onTogglePreferred,
    });

    enterEdit();
    fireEvent.click(screen.getByRole('button', { name: 'Pin ❤️' }));

    expect(onTogglePreferred).toHaveBeenCalledTimes(1);
    expect(onTogglePreferred).toHaveBeenCalledWith(['🎉', '❤️']);
    expect(onApply).not.toHaveBeenCalled();
    expect(screen.getByRole('button', { name: '🎉' })).toHaveAttribute('aria-pressed', 'true');
    expect(screen.getByRole('button', { name: '👍' })).toHaveAttribute('aria-pressed', 'true');
    expect(screen.getByRole('button', { name: '❤️' })).toHaveAttribute('aria-pressed', 'false');
  });

  it('unpins with the star without changing the filter draft', () => {
    const onTogglePreferred = jest.fn();

    renderPicker({
      appliedEmojis: ['🎉', '👍'],
      preferredEmojis: ['🎉', '👍', '❤️'],
      onTogglePreferred,
    });

    enterEdit();
    fireEvent.click(screen.getByRole('button', { name: 'Unpin 👍' }));

    expect(onTogglePreferred).toHaveBeenCalledTimes(1);
    expect(onTogglePreferred).toHaveBeenCalledWith(['🎉', '❤️']);
    expect(screen.getByRole('button', { name: '🎉' })).toHaveAttribute('aria-pressed', 'true');
    expect(screen.getByRole('button', { name: '👍' })).toHaveAttribute('aria-pressed', 'true');
  });

  it('applies a single toggle when an unselected emoji is double-clicked', () => {
    const { onApply } = renderPicker({ appliedEmojis: [] });
    const tile = screen.getByRole('button', { name: '🎉' });

    clickTile(tile, 1);
    clickTile(tile, 2);
    fireEvent.doubleClick(tile);

    expect(onApply).toHaveBeenCalledTimes(1);
    expect(onApply).toHaveBeenCalledWith(['🎉']);
    expect(tile).toHaveAttribute('aria-pressed', 'true');
  });

  it('applies a single toggle when a selected emoji is double-clicked', () => {
    const { onApply } = renderPicker({ appliedEmojis: ['🎉', '👍'] });
    const tile = screen.getByRole('button', { name: '🎉' });

    clickTile(tile, 1);
    clickTile(tile, 2);
    fireEvent.doubleClick(tile);

    expect(onApply).toHaveBeenCalledTimes(1);
    expect(onApply).toHaveBeenCalledWith(['👍']);
    expect(tile).toHaveAttribute('aria-pressed', 'false');
    expect(screen.getByRole('button', { name: '👍' })).toHaveAttribute('aria-pressed', 'true');
  });

  it('ignores the second click of a double-click', () => {
    renderPicker({ appliedEmojis: [] });
    const tile = screen.getByRole('button', { name: '🎉' });

    clickTile(tile, 1);
    clickTile(tile, 2);

    expect(tile).toHaveAttribute('aria-pressed', 'true');
  });

  it('does not apply a filter when a touch double-tap selects an emoji', () => {
    const { onApply } = renderPicker({ appliedEmojis: [] });
    const tile = screen.getByRole('button', { name: '🎉' });

    pointer(tile, 'pointerDown', 10, 10, 'touch');
    pointer(tile, 'pointerUp', 10, 10, 'touch');
    clickTile(tile, 1);
    pointer(tile, 'pointerDown', 10, 10, 'touch');
    pointer(tile, 'pointerUp', 10, 10, 'touch');
    clickTile(tile, 2);
    fireEvent.doubleClick(tile);

    expect(onApply).not.toHaveBeenCalled();
    expect(tile).toHaveAttribute('aria-pressed', 'true');
  });

  it('does not change the filter draft from clicks while editing pinned emoji', () => {
    const { onApply } = renderPicker({ appliedEmojis: ['🎉'] });

    enterEdit();
    const selected = screen.getByRole('button', { name: '🎉' });
    const unselected = screen.getByRole('button', { name: '👍' });

    expect(selected).toHaveAttribute('aria-disabled', 'true');
    clickTile(selected, 1);
    clickTile(unselected, 1);
    clickTile(unselected, 2);
    fireEvent.doubleClick(unselected);

    expect(onApply).not.toHaveBeenCalled();
    expect(selected).toHaveAttribute('aria-pressed', 'true');
    expect(unselected).toHaveAttribute('aria-pressed', 'false');
    expect(screen.getByText('1 emojis selected')).toBeInTheDocument();
  });

  it('drops an unpinned emoji into the pinned list once', () => {
    const onTogglePreferred = jest.fn();
    const restore = installLayout({
      '🎉': rect(0, 40, 90, 80),
      '👍': rect(100, 40, 90, 80),
    });

    renderPicker({
      appliedEmojis: ['🎉'],
      preferredEmojis: ['🎉', '👍'],
      onTogglePreferred,
    });
    enterEdit();

    const heart = screen.getByRole('button', { name: '❤️' });

    pointer(heart, 'pointerDown', 10, 400);
    pointer(heart, 'pointerMove', 40, 400);
    pointer(heart, 'pointerMove', 95, 80);
    expect(onTogglePreferred).not.toHaveBeenCalled();
    expect(pinnedFlow()).toEqual(['🎉', 'placeholder', '👍']);
    expectFloatingOverlay(heart);
    expect(heart.closest('.emoji-reaction-filter-picker__body')).not.toBeNull();
    pointer(heart, 'pointerUp', 95, 80);
    expect(dragOverlay()).toBeNull();
    fireEvent.click(heart);

    expect(onTogglePreferred).toHaveBeenCalledTimes(1);
    expect(onTogglePreferred).toHaveBeenCalledWith(['🎉', '❤️', '👍']);
    expect(heart).toHaveAttribute('aria-pressed', 'false');
    expect(screen.getByRole('button', { name: '🎉' })).toHaveAttribute('aria-pressed', 'true');
    restore();
  });

  it('reorders pinned emoji when one is dropped at a new index', () => {
    const onTogglePreferred = jest.fn();
    const restore = installLayout({
      '🥳': rect(0, 40, 90, 80),
      '🎉': rect(100, 40, 90, 80),
      '👍': rect(200, 40, 90, 80),
    });

    renderPicker({
      catalogItems: [
        { name: '🥳', custom: false, domain: null, count: 3 },
        { name: '🎉', custom: false, domain: null, count: 2 },
        { name: '👍', custom: false, domain: null, count: 1 },
      ],
      preferredEmojis: ['🥳', '🎉', '👍'],
      onTogglePreferred,
    });
    enterEdit();

    const thumb = screen.getByRole('button', { name: '👍' });

    pointer(thumb, 'pointerDown', 220, 80);
    pointer(thumb, 'pointerMove', 10, 80);
    expect(onTogglePreferred).not.toHaveBeenCalled();
    expect(document.querySelector('[data-drop-zone="true"]')).toHaveClass('is-drop-target');
    expect(pinnedFlow()).toEqual(['placeholder', '🥳', '🎉']);
    expectFloatingOverlay(thumb);
    expect(thumb.closest('.emoji-reaction-filter-picker__pinned')).not.toBeNull();
    pointer(thumb, 'pointerMove', 140, 80);
    expect(pinnedFlow()).toEqual(['🥳', 'placeholder', '🎉']);
    pointer(thumb, 'pointerMove', 10, 80);
    pointer(thumb, 'pointerUp', 10, 80);

    expect(dragOverlay()).toBeNull();
    expect(onTogglePreferred).toHaveBeenCalledTimes(1);
    expect(onTogglePreferred).toHaveBeenCalledWith(['👍', '🥳', '🎉']);
    restore();
  });

  it('does not change pinned emoji when the drop misses the zone', () => {
    const onTogglePreferred = jest.fn();
    const restore = installLayout({
      '🎉': rect(0, 40, 90, 80),
      '👍': rect(100, 40, 90, 80),
    });

    renderPicker({
      preferredEmojis: ['🎉', '👍'],
      onTogglePreferred,
    });
    enterEdit();

    const heart = screen.getByRole('button', { name: '❤️' });

    pointer(heart, 'pointerDown', 10, 400);
    pointer(heart, 'pointerMove', 30, 400);
    pointer(heart, 'pointerMove', 80, 420);
    expectFloatingOverlay(heart);
    pointer(heart, 'pointerUp', 80, 420);

    expect(dragOverlay()).toBeNull();
    expect(onTogglePreferred).not.toHaveBeenCalled();
    restore();
  });

  it('does not pin below the visible pinned viewport when the section is taller', () => {
    const onTogglePreferred = jest.fn();
    const restore = installLayout({
      '🎉': rect(0, 40, 90, 80),
      '👍': rect(100, 40, 90, 80),
    }, {
      viewport: rect(0, 0, 320, 180),
      section: rect(0, 0, 320, 1000),
    });

    renderPicker({
      preferredEmojis: ['🎉', '👍'],
      onTogglePreferred,
    });
    enterEdit();

    const heart = screen.getByRole('button', { name: '❤️' });

    pointer(heart, 'pointerDown', 10, 500);
    pointer(heart, 'pointerMove', 40, 500);
    pointer(heart, 'pointerMove', 80, 200);
    pointer(heart, 'pointerUp', 80, 200);

    expect(onTogglePreferred).not.toHaveBeenCalled();
    expect(document.querySelector('[data-drop-zone="true"]')).not.toHaveClass('is-drop-target');
    restore();
  });

  describe('long press preview', () => {
    beforeEach(() => {
      jest.useFakeTimers();
    });

    afterEach(() => {
      jest.useRealTimers();
    });

    it('shows a preview only after the delay and does not toggle on release', () => {
      renderPicker({ appliedEmojis: [] });
      const tile = screen.getByRole('button', { name: '👍' });

      pointer(tile, 'pointerDown', 8, 8);
      act(() => {
        jest.advanceTimersByTime(449);
      });

      expect(screen.queryByTestId('emoji-reaction-filter-preview')).not.toBeInTheDocument();

      act(() => {
        jest.advanceTimersByTime(1);
      });

      const preview = screen.getByTestId('emoji-reaction-filter-preview');

      expect(preview).toHaveTextContent('👍');

      pointer(tile, 'pointerUp', 8, 8);

      expect(screen.queryByTestId('emoji-reaction-filter-preview')).not.toBeInTheDocument();

      fireEvent.click(tile);

      expect(tile).toHaveAttribute('aria-pressed', 'false');
    });

    it('previews a custom emoji with its original url', () => {
      renderPicker();
      const tile = screen.getByRole('button', { name: ':achievement:@example.com' });

      pointer(tile, 'pointerDown', 12, 12);
      act(() => {
        jest.advanceTimersByTime(450);
      });

      const preview = screen.getByTestId('emoji-reaction-filter-preview');

      expect(preview).toHaveTextContent(':achievement:@example.com');
      expect(preview.querySelector('img')).toHaveAttribute('data-url', 'https://cdn.example/achievement.png');
      expect(preview.querySelector('img')).toHaveAttribute('data-domain', 'example.com');

      pointer(tile, 'pointerUp', 12, 12);
    });

    it('cancels the preview when the pointer moves past the drag threshold', () => {
      renderPicker();
      const tile = screen.getByRole('button', { name: '👍' });

      pointer(tile, 'pointerDown', 0, 0);
      pointer(tile, 'pointerMove', 20, 0);
      act(() => {
        jest.advanceTimersByTime(500);
      });

      expect(screen.queryByTestId('emoji-reaction-filter-preview')).not.toBeInTheDocument();

      pointer(tile, 'pointerUp', 20, 0);
      fireEvent.click(tile);

      expect(tile).toHaveAttribute('aria-pressed', 'false');
    });

    it('starts a drag instead of a preview while editing', () => {
      const onTogglePreferred = jest.fn();

      renderPicker({ preferredEmojis: ['🎉'], onTogglePreferred });
      enterEdit();

      const tile = screen.getByRole('button', { name: '👍' });

      pointer(tile, 'pointerDown', 0, 400);
      pointer(tile, 'pointerMove', 24, 400);
      act(() => {
        jest.advanceTimersByTime(500);
      });

      expect(screen.queryByTestId('emoji-reaction-filter-preview')).not.toBeInTheDocument();
      expect(tile.parentElement).toHaveClass('is-drag-source');

      pointer(tile, 'pointerUp', 24, 400);

      expect(onTogglePreferred).not.toHaveBeenCalled();
    });

    it('does not swallow an unrelated button after pointercancel', () => {
      renderPicker();
      enterEdit();

      const tile = screen.getByRole('button', { name: '👍' });

      pointer(tile, 'pointerDown', 0, 400);
      pointer(tile, 'pointerMove', 24, 400);
      pointer(tile, 'pointerCancel', 24, 400);
      fireEvent.click(screen.getByRole('button', { name: 'Done' }));

      expect(screen.getByRole('button', { name: 'Edit pinned' })).toHaveAttribute('aria-pressed', 'false');
      expect(tile).toHaveAttribute('aria-pressed', 'false');
    });

    it('still leaves Done usable immediately after a drag', () => {
      const onTogglePreferred = jest.fn();
      const restore = installLayout({
        '🎉': rect(0, 40, 90, 80),
        '👍': rect(100, 40, 90, 80),
      });

      renderPicker({
        preferredEmojis: ['🎉', '👍'],
        onTogglePreferred,
      });
      enterEdit();

      const heart = screen.getByRole('button', { name: '❤️' });

      pointer(heart, 'pointerDown', 10, 400);
      pointer(heart, 'pointerMove', 40, 400);
      pointer(heart, 'pointerMove', 95, 80);
      pointer(heart, 'pointerUp', 95, 80);
      fireEvent.click(screen.getByRole('button', { name: 'Done' }));

      expect(onTogglePreferred).toHaveBeenCalledTimes(1);
      expect(screen.getByRole('button', { name: 'Edit pinned' })).toHaveAttribute('aria-pressed', 'false');
      expect(heart).toHaveAttribute('aria-pressed', 'false');
      restore();
    });

    it('suppresses the context menu only after the preview opens', () => {
      renderPicker();
      const tile = screen.getByRole('button', { name: '👍' });

      expect(fireEvent.contextMenu(tile)).toBe(true);

      pointer(tile, 'pointerDown', 6, 6);
      act(() => {
        jest.advanceTimersByTime(450);
      });

      expect(fireEvent.contextMenu(tile)).toBe(false);

      pointer(tile, 'pointerUp', 6, 6);
    });
  });
});
