/* eslint-disable react/prop-types */

import { fireEvent, render, screen } from '@testing-library/react';
import { fromJS, List as ImmutableList } from 'immutable';
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
import AccountMediaItems from '../components/media_items';

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

  it('forgets an individual reveal even when returning to the same visibility policy', () => {
    const { rerender } = render(tile('hide_all'));
    fireEvent.click(screen.getByRole('link', { name: 'メディアを表示' }));
    expect(screen.getByRole('link', { name: '写真の説明' })).toBeInTheDocument();

    rerender(tile('show_all'));
    rerender(tile('hide_all'));
    expect(screen.getByRole('link', { name: 'メディアを表示' })).toBeInTheDocument();
    expect(screen.queryByRole('link', { name: '写真の説明' })).toBeNull();

    fireEvent.click(screen.getByRole('link', { name: 'メディアを表示' }));
    rerender(tile('hide_sensitive'));
    rerender(tile('hide_all'));
    expect(screen.getByRole('link', { name: 'メディアを表示' })).toBeInTheDocument();
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

const IntegratedGallery = ({ shape = 'square', medias }) => {
  const [visibility, setVisibility] = React.useState('hide_all');
  const ordinary = attachment
    .set('id', 'm2')
    .setIn(['status', 'id'], '11')
    .setIn(['status', 'sensitive'], false);
  const items = medias || [attachment, ordinary];
  return (
    <IntlProvider locale='ja' messages={japanese}>
      <div>
        <MediaDisplayControls
          shape={shape}
          size='medium'
          visibility={visibility}
          onShapeChange={jest.fn()}
          onSizeChange={jest.fn()}
          onVisibilityChange={setVisibility}
        />
        <AccountMediaItems
          attachments={ImmutableList(items)}
          shape={shape}
          size='medium'
          visibility={visibility}
          onOpenMedia={onOpenMedia}
          onReveal={onReveal}
          onLoadMore={jest.fn()}
        />
      </div>
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

describe('account original-size masonry visibility transitions', () => {
  it('keeps original-size masonry placements when all media visibility controls change', () => {
    const resizeObserver = Object.getOwnPropertyDescriptor(window, 'ResizeObserver');
    Object.defineProperty(window, 'ResizeObserver', { configurable: true, value: undefined });

    const itemHeights = { m1: 320, m2: 90, m3: 90, m4: 90 };
    const rect = (width, height) => ({ width, height, x: 0, y: 0, top: 0, left: 0, right: width, bottom: height });

    jest.spyOn(Element.prototype, 'getBoundingClientRect').mockImplementation(function () {
      if (this.classList.contains('timeline-masonry')) {
        return rect(350, 0); // Two medium-size columns.
      }

      const key = this.getAttribute('data-layout-key');
      const mediaId = key && Object.keys(itemHeights).find(id => key.includes(id));
      return rect(0, mediaId ? itemHeights[mediaId] : 0);
    });

    try {
      const medias = [
        attachment,
        ...['m2', 'm3', 'm4'].map((id, index) => attachment
          .set('id', id)
          .setIn(['status', 'id'], String(index + 11))
          .setIn(['status', 'sensitive'], false)),
      ];
      const { container } = render(<IntegratedGallery shape='original' medias={medias} />);
      const findItem = id => Array.from(container.querySelectorAll('.timeline-masonry__item'))
        .find(node => node.getAttribute('data-layout-key')?.includes(id));
      const position = id => {
        const node = findItem(id);
        const match = node.style.transform.match(/translate3d\(0, ([\d.]+)px, 0\)/);
        return { x: parseFloat(node.style.insetInlineStart), y: Number(match[1]) };
      };
      const ids = ['m1', 'm2', 'm3', 'm4'];
      const initialNodes = ids.map(findItem);
      const initialPositions = ids.map(position);

      // A tall image occupies the first column, while shorter images
      // stack tightly in the second, rather than forming uniform rows.
      expect(initialPositions[1].x).toBeGreaterThan(initialPositions[0].x);
      expect(initialPositions[2].x).toBe(initialPositions[1].x);
      expect(initialPositions[3].x).toBe(initialPositions[1].x);
      expect(initialPositions[2].y).toBe(initialPositions[1].y + 98);
      expect(container.querySelectorAll('.timeline-media-tile__open--original')).toHaveLength(4);

      [
        { label: '閲覧注意メディアを隠す', images: 3, blurred: 1 },
        { label: 'メディアを常に表示する', images: 4, blurred: 0 },
        { label: 'メディアを常に隠す', images: 0, blurred: 4 },
      ].forEach(({ label, images, blurred }) => {
        fireEvent.click(screen.getByRole('button', { name: label }));
        expect(ids.map(position)).toEqual(initialPositions);
        expect(ids.map(findItem)).toEqual(initialNodes);
        expect(container.querySelectorAll('.timeline-media-tile__open--original')).toHaveLength(4);
        expect(container.querySelectorAll('.timeline-media-tile img')).toHaveLength(images);
        expect(container.querySelectorAll('[data-testid="blurhash-canvas"]')).toHaveLength(blurred);
      });
    } finally {
      jest.restoreAllMocks();
      if (resizeObserver) {
        Object.defineProperty(window, 'ResizeObserver', resizeObserver);
      } else {
        delete window.ResizeObserver;
      }
    }
  });
});
