import { render, screen } from '@testing-library/react';
import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
import React from 'react';

jest.mock('mastodon/initial_state', () => ({
  autoPlayEmoji: false,
}));

import { identityDisplayNameNodes } from '../display_name';

const emojis = ImmutableList([
  ImmutableMap({
    shortcode: 'blob',
    url: 'https://cdn.example/blob.gif',
    static_url: 'https://cdn.example/blob.png',
  }),
]);

describe('identityDisplayNameNodes', () => {
  it('renders a known custom emoji and leaves unknown shortcodes as text', () => {
    render(<span>{identityDisplayNameNodes('Hi :blob: :missing: <b>', emojis)}</span>);

    const image = screen.getByRole('img', { name: ':blob:' });

    expect(image).toHaveAttribute('src', 'https://cdn.example/blob.png');
    expect(image).toHaveAttribute('data-shortcode', 'blob');
    expect(screen.getByText(/Hi/)).toBeTruthy();
    expect(document.body.textContent).toContain(':missing:');
    expect(document.body.textContent).toContain('<b>');
    expect(document.querySelector('b')).toBeNull();
  });

  it('keeps a plain display name as text', () => {
    render(<span>{identityDisplayNameNodes('Alice', emojis)}</span>);

    expect(screen.getByText('Alice')).toBeTruthy();
    expect(document.querySelector('img')).toBeNull();
  });
});
