import { fireEvent, render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { addLocaleData, IntlProvider } from 'react-intl';
import japaneseData from 'react-intl/locale-data/ja';
import japanese from 'mastodon/locales/ja.json';

jest.mock('mastodon/initial_state', () => ({
  autoPlayMedia: false,
  displayMedia: 'default',
  useBlurhash: false,
}));
jest.mock('mastodon/is_mobile', () => ({ isIOS: () => false }));
jest.mock('mastodon/components/alt_text_badge', () => {
  const ReactMock = require('react');
  return ({ description }) => ReactMock.createElement('button', { type: 'button', 'aria-label': `ALT: ${description}` }, 'ALT');
});
jest.mock('mastodon/components/blurhash', () => () => null);
jest.mock('mastodon/components/thumbhash', () => () => null);
jest.mock('mastodon/components/icon', () => {
  const ReactMock = require('react');
  return ({ id }) => ReactMock.createElement('span', { 'data-icon': id });
});

import MediaItem from '../components/media_item';

addLocaleData(japaneseData);

const attachment = fromJS({
  id: 'm1',
  type: 'image',
  description: '写真の説明',
  preview_url: '/preview.jpg',
  meta: { original: { width: 200, height: 400 } },
  status: {
    id: '10',
    url: '/statuses/10',
    sensitive: true,
    spoiler_text: '',
  },
});
const onOpenMedia = jest.fn();

const tile = visibility => (
  <IntlProvider locale='ja' messages={japanese}>
    <MediaItem
      attachment={attachment}
      shape='original'
      visibility={visibility}
      onOpenMedia={onOpenMedia}
    />
  </IntlProvider>
);

describe('account media gallery tile', () => {
  beforeEach(() => {
    onOpenMedia.mockClear();
  });

  it('shows ALT while the sensitive image is hidden, and reveals only this tile', () => {
    const { container } = render(tile('hide_sensitive'));
    expect(screen.getByRole('button', { name: 'ALT: 写真の説明' })).toBeInTheDocument();
    const link = screen.getByRole('link', { name: 'メディアを表示' });
    expect(container.querySelector('img')).toBeNull();
    expect(link.style.aspectRatio).toBe('0.5');

    fireEvent.click(link);
    expect(onOpenMedia).not.toHaveBeenCalled();
    expect(container.querySelector('img')).toHaveAttribute('src', '/preview.jpg');

    fireEvent.click(screen.getByRole('link', { name: '写真の説明' }));
    expect(onOpenMedia).toHaveBeenCalledWith(attachment);
  });

  it('resets individual reveal when the column visibility policy changes', () => {
    const { rerender } = render(tile('hide_all'));
    fireEvent.click(screen.getByRole('link', { name: 'メディアを表示' }));
    expect(screen.getByRole('link', { name: '写真の説明' })).toBeInTheDocument();

    rerender(tile('hide_sensitive'));
    expect(screen.getByRole('link', { name: 'メディアを表示' })).toBeInTheDocument();

    rerender(tile('show_all'));
    expect(screen.getByRole('link', { name: '写真の説明' })).toBeInTheDocument();
  });
});
