/* eslint-disable react/prop-types */

import { fireEvent, render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { addLocaleData, IntlProvider } from 'react-intl';
import japaneseData from 'react-intl/locale-data/ja';
import japanese from 'mastodon/locales/ja.json';

jest.mock('mastodon/initial_state', () => ({
  autoPlayMedia: false,
  displayMedia: 'default',
  useBlurhash: true,
}));
jest.mock('mastodon/is_mobile', () => ({ isIOS: () => false }));
jest.mock('mastodon/components/alt_text_badge', () => {
  const ReactMock = require('react');
  return ({ description }) => ReactMock.createElement('button', { type: 'button', 'aria-label': `ALT: ${description}` }, 'ALT');
});
jest.mock('mastodon/components/blurhash', () => () => <canvas data-testid='blurhash-canvas' />);
jest.mock('mastodon/components/thumbhash', () => () => null);
jest.mock('mastodon/components/icon', () => {
  const ReactMock = require('react');
  return ({ id }) => ReactMock.createElement('span', { 'data-icon': id });
});

import MediaItem from '../components/media_item';
import MediaDisplayControls from 'mastodon/components/media_display_controls';

addLocaleData(japaneseData);

const attachment = fromJS({
  id: 'm1',
  type: 'image',
  description: '写真の説明',
  preview_url: '/preview.jpg',
  blurhash: 'LEHV6nWB2yk8pyo0adR*.7kCMdnj',
  meta: { original: { width: 200, height: 400 } },
  status: {
    id: '10',
    url: '/statuses/10',
    sensitive: true,
    spoiler_text: '',
  },
});
const onOpenMedia = jest.fn();
const onReveal = jest.fn();

const tile = (visibility, media = attachment) => (
  <IntlProvider locale='ja' messages={japanese}>
    <MediaItem
      attachment={media}
      shape='original'
      visibility={visibility}
      onOpenMedia={onOpenMedia}
      onReveal={onReveal}
    />
  </IntlProvider>
);

describe('account media gallery tile', () => {
  beforeEach(() => {
    onOpenMedia.mockClear();
    onReveal.mockClear();
  });

  it('shows ALT while the sensitive image is hidden, and reveals only this tile', () => {
    const { container } = render(tile('hide_sensitive'));
    expect(screen.getByRole('button', { name: 'ALT: 写真の説明' })).toBeInTheDocument();
    const link = screen.getByRole('link', { name: 'メディアを表示' });
    expect(container.querySelector('img')).toBeNull();
    expect(screen.getByTestId('blurhash-canvas')).toBeInTheDocument();
    expect(link.style.aspectRatio).toBe('0.5');

    fireEvent.click(link);
    expect(onOpenMedia).not.toHaveBeenCalled();
    expect(onReveal).toHaveBeenCalledWith(attachment);
    expect(container.querySelector('img')).toHaveAttribute('src', '/preview.jpg');
    expect(screen.queryByTestId('blurhash-canvas')).toBeNull();

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
    expect(screen.queryByTestId('blurhash-canvas')).toBeNull();
  });

  it('shows clear previews when toggling from hide-all to sensitive-only and show-all', () => {
    const ordinary = attachment.setIn(['status', 'sensitive'], false);
    const { container, rerender } = render(tile('hide_all', ordinary));
    expect(screen.getByTestId('blurhash-canvas')).toBeInTheDocument();
    expect(container.querySelector('img')).toBeNull();

    rerender(tile('hide_sensitive', ordinary));
    expect(screen.queryByTestId('blurhash-canvas')).toBeNull();
    expect(container.querySelector('img')).toHaveAttribute('src', '/preview.jpg');

    rerender(tile('show_all', ordinary));
    expect(screen.queryByTestId('blurhash-canvas')).toBeNull();
    expect(container.querySelector('img')).toHaveAttribute('src', '/preview.jpg');

    rerender(tile('hide_all', ordinary));
    expect(screen.getByTestId('blurhash-canvas')).toBeInTheDocument();
    expect(container.querySelector('img')).toBeNull();

    rerender(tile('show_all', ordinary));
    expect(screen.queryByTestId('blurhash-canvas')).toBeNull();
    expect(container.querySelector('img')).toHaveAttribute('src', '/preview.jpg');
  });

  it('does not retain a stale blur overlay when switching sensitive media to show-all', () => {
    const { container, rerender } = render(tile('hide_sensitive'));
    expect(screen.getByTestId('blurhash-canvas')).toBeInTheDocument();

    rerender(tile('show_all'));
    expect(screen.queryByTestId('blurhash-canvas')).toBeNull();
    expect(container.querySelector('img')).toHaveAttribute('src', '/preview.jpg');

    rerender(tile('hide_sensitive'));
    expect(screen.getByTestId('blurhash-canvas')).toBeInTheDocument();
    expect(container.querySelector('img')).toBeNull();
  });
});

const IntegratedGallery = () => {
  const [visibility, setVisibility] = React.useState('hide_all');
  const ordinary = attachment
    .set('id', 'm2')
    .setIn(['status', 'id'], '11')
    .setIn(['status', 'sensitive'], false);
  return (
    <IntlProvider locale='ja' messages={japanese}>
      <MediaDisplayControls
        shape='square'
        size='small'
        visibility={visibility}
        onShapeChange={jest.fn()}
        onSizeChange={jest.fn()}
        onVisibilityChange={setVisibility}
      />
      {[attachment, ordinary].map(media => (
        <MediaItem
          key={`${media.get('id')}:${visibility}`}
          attachment={media}
          visibility={visibility}
          shape='square'
          onOpenMedia={onOpenMedia}
        />
      ))}
    </IntlProvider>
  );
};

describe('account media control transitions', () => {
  it('shows only sensitive blurred media in hide-sensitive mode, and none in show-all mode', () => {
    const { container } = render(<IntegratedGallery />);
    const images = () => container.querySelectorAll('.timeline-media-tile img');
    const blurred = () => container.querySelectorAll('[data-testid="blurhash-canvas"]');

    expect(images()).toHaveLength(0);
    expect(blurred()).toHaveLength(2);

    fireEvent.click(screen.getByRole('button', { name: '閲覧注意メディアを隠す' }));
    expect(images()).toHaveLength(1);
    expect(blurred()).toHaveLength(1);

    fireEvent.click(screen.getByRole('button', { name: 'メディアを常に表示する' }));
    expect(images()).toHaveLength(2);
    expect(blurred()).toHaveLength(0);

    fireEvent.click(screen.getByRole('button', { name: '閲覧注意メディアを隠す' }));
    expect(images()).toHaveLength(1);
    expect(blurred()).toHaveLength(1);

    fireEvent.click(screen.getByRole('button', { name: 'メディアを常に隠す' }));
    expect(images()).toHaveLength(0);
    expect(blurred()).toHaveLength(2);

    fireEvent.click(screen.getByRole('button', { name: 'メディアを常に表示する' }));
    expect(images()).toHaveLength(2);
    expect(blurred()).toHaveLength(0);
  });
});
