/* eslint-disable react/prop-types */

import { fireEvent, render, screen } from '@testing-library/react';
import React from 'react';

jest.mock('mastodon/initial_state', () => ({
  languages: [
    ['en', 'English', 'English'],
    ['ja', 'Japanese', '日本語'],
  ],
}));

jest.mock('react-intl', () => ({
  FormattedMessage: ({ defaultMessage }) => defaultMessage,
}));

import AltTextBadge from '../alt_text_badge';

const renderBadge = (props) => render(
  <AltTextBadge
    originalDescription='a cat'
    translatedDescription='ねこ'
    sourceLang='en'
    targetLang='ja'
    {...props}
  />,
);

describe('AltTextBadge translation display modes', () => {
  it('shows the original description in original mode', () => {
    renderBadge({ mode: 'original' });
    fireEvent.click(screen.getByRole('button', { name: 'ALT' }));

    expect(screen.getByText('a cat')).toBeTruthy();
    expect(screen.queryByText('ねこ')).toBeNull();
    expect(screen.getByText('English → 日本語')).toBeTruthy();
    expect(screen.getByText('a cat').getAttribute('lang')).toBe('en');
  });

  it('shows the translated description in translated mode', () => {
    renderBadge({ mode: 'translated' });
    fireEvent.click(screen.getByRole('button', { name: 'ALT' }));

    expect(screen.getByText('ねこ').getAttribute('lang')).toBe('ja');
    expect(screen.queryByText('a cat')).toBeNull();
  });

  it('shows both descriptions in the bilingual popover', () => {
    renderBadge({ mode: 'bilingual' });
    fireEvent.click(screen.getByRole('button', { name: 'ALT' }));

    const source = screen.getByText('a cat');
    const target = screen.getByText('ねこ');

    expect(source.getAttribute('lang')).toBe('en');
    expect(source.className).toContain('status-translation-pair__source');
    expect(target.getAttribute('lang')).toBe('ja');
    expect(target.className).toContain('status-translation-pair__target');
    expect(screen.getByText('Alt text')).toBeTruthy();
    expect(screen.getByText('English → 日本語')).toBeTruthy();
  });

  it('falls back to the original description when the translation is empty', () => {
    renderBadge({ mode: 'translated', translatedDescription: '' });
    fireEvent.click(screen.getByRole('button', { name: 'ALT' }));

    expect(screen.getByText('a cat').getAttribute('lang')).toBe('en');
    expect(screen.queryByText('English → 日本語')).toBeNull();
  });
});
