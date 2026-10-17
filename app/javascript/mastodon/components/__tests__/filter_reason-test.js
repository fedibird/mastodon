import { render, screen } from '@testing-library/react';
import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
import React from 'react';

jest.mock('mastodon/initial_state', () => ({
  autoPlayEmoji: false,
}));

import { FilterReason } from '../filter_reason';

const catalog = ImmutableList([
  ImmutableMap({
    shortcode: 'known',
    url: 'https://cdn.example.test/known.gif',
    static_url: 'https://cdn.example.test/known.png',
    alternate_name: 'Known emoji',
  }),
  ImmutableMap({
    shortcode: 'other',
    url: 'https://cdn.example.test/other.gif',
    static_url: 'https://cdn.example.test/other.png',
  }),
  ImmutableMap({
    shortcode: 'blank',
    url: '',
    static_url: '',
  }),
]);

const renderReason = (titles, customEmojis = catalog) => render(
  <span data-testid='reason'>
    <FilterReason titles={titles} customEmojis={customEmojis} />
  </span>,
);

const reason = () => screen.getByTestId('reason');

describe('FilterReason', () => {
  it('renders a plain title as text', () => {
    renderReason(['普通の理由']);

    expect(reason().textContent).toBe('普通の理由');
    expect(reason().querySelector('img')).toBeNull();
  });

  it('renders a known local shortcode as an image and keeps surrounding text', () => {
    renderReason(['重要 :known: 話題']);

    const image = screen.getByRole('img', { name: ':known:' });

    expect(image).toHaveAttribute('src', 'https://cdn.example.test/known.png');
    expect(image).toHaveAttribute('data-shortcode', 'known');
    expect(image).toHaveAttribute('data-original', 'https://cdn.example.test/known.gif');
    expect(image).toHaveAttribute('data-static', 'https://cdn.example.test/known.png');
    expect(image).toHaveAttribute('title', 'Known emoji');
    expect(image).toHaveClass('custom-emoji');
    expect(reason().textContent).toContain('重要 ');
    expect(reason().textContent).toContain(' 話題');
    expect(reason().textContent).not.toContain(':known:');
  });

  it('renders adjacent shortcodes as separate images', () => {
    renderReason([':known::other:']);

    const images = reason().querySelectorAll('img.custom-emoji');

    expect(images).toHaveLength(2);
    expect(images[0]).toHaveAttribute('alt', ':known:');
    expect(images[1]).toHaveAttribute('alt', ':other:');
    expect(images[0].nextSibling).toBe(images[1]);
  });

  it('keeps punctuation beside a shortcode', () => {
    renderReason(['確認 :known:。']);

    expect(screen.getByRole('img', { name: ':known:' })).toBeInTheDocument();
    expect(reason().textContent).toContain('確認 ');
    expect(reason().textContent).toContain('。');
  });

  it('leaves an unknown shortcode as text', () => {
    renderReason(['確認 :unknown:']);

    expect(reason().querySelector('img')).toBeNull();
    expect(reason().textContent).toBe('確認 :unknown:');
  });

  it('keeps an unknown shortcode intact when a later shortcode is known', () => {
    renderReason([':unknown::known:']);

    expect(screen.getByRole('img', { name: ':known:' })).toBeInTheDocument();
    expect(reason().textContent).toContain(':unknown:');
  });

  it('leaves a catalog entry without image URLs as text', () => {
    renderReason([':blank:']);

    expect(reason().querySelector('img')).toBeNull();
    expect(reason().textContent).toBe(':blank:');
  });

  it('joins several filter titles with a comma and space', () => {
    renderReason(['理由A :known:', '理由B']);

    const image = screen.getByRole('img', { name: ':known:' });

    expect(image.previousSibling.textContent).toBe('理由A ');
    expect(image.nextSibling.textContent).toBe(', ');
    expect(reason().textContent).toContain('理由B');
    expect(reason().textContent).toContain('理由A ');
    expect(reason().textContent).toContain(', ');
  });

  it('does not interpret the title as HTML', () => {
    renderReason(['<img src=x onerror=alert(1)> :known:']);

    const images = reason().querySelectorAll('img');

    expect(images).toHaveLength(1);
    expect(images[0]).toHaveAttribute('src', 'https://cdn.example.test/known.png');
    expect(reason().textContent).toContain('<img src=x onerror=alert(1)>');
    expect(reason().querySelector('script')).toBeNull();
  });

  it('renders shortcodes as text until the local catalog arrives', () => {
    const { rerender } = renderReason(['確認 :known:'], ImmutableList());

    expect(reason().querySelector('img')).toBeNull();
    expect(reason().textContent).toBe('確認 :known:');

    rerender(
      <span data-testid='reason'>
        <FilterReason titles={['確認 :known:']} customEmojis={catalog} />
      </span>,
    );

    expect(screen.getByRole('img', { name: ':known:' })).toHaveAttribute('src', 'https://cdn.example.test/known.png');
  });

  it('renders nothing for an empty title list', () => {
    renderReason([]);

    expect(reason().textContent).toBe('');
    expect(reason().querySelector('img')).toBeNull();
  });
});
