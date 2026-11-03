/* eslint-disable react/prop-types */

import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import React from 'react';
import { addLocaleData, IntlProvider } from 'react-intl';
import japaneseLocaleData from 'react-intl/locale-data/ja';
import japanese from 'mastodon/locales/ja.json';

jest.mock('react-redux-loading-bar', () => ({
  LoadingBar: () => null,
}));

jest.mock('../zoomable_image', () => ({
  __esModule: true,
  default: ({ alt, src, onError }) => <img alt={alt} src={src} onError={onError} />,
}));

import ImageLoader from '../image_loader';

addLocaleData(japaneseLocaleData);

const renderImage = props => render(
  <IntlProvider locale='ja' messages={japanese}>
    <ImageLoader {...props} />
  </IntlProvider>,
);

class MockPreloadImage {
  listeners = {};

  addEventListener (type, handler) {
    this.listeners[type] = handler;
  }

  removeEventListener (type, handler) {
    if (this.listeners[type] === handler) delete this.listeners[type];
  }

  set src (value) {
    Promise.resolve().then(() => {
      const handler = this.listeners[value.includes('missing') ? 'error' : 'load'];
      if (handler) handler();
    });
  }
}

describe('image lightbox failure and ALT fallback', () => {
  const OriginalImage = global.Image;

  beforeEach(() => {
    global.Image = MockPreloadImage;
  });

  afterEach(() => {
    global.Image = OriginalImage;
  });

  it('shows a bounded ALT region instead of a broken image even when no dimensions were provided', async () => {
    const longAlt = '写真に関する詳しい説明。'.repeat(40);
    const { container } = renderImage({ src: '/missing-photo.jpg', alt: longAlt, lang: 'ja' });

    await waitFor(() => expect(screen.getByRole('status')).toHaveTextContent('取得できませんでした'));
    expect(container.querySelector('.image-loader__error')).toBeInTheDocument();
    expect(container.querySelector('.image-loader__error-alt')).toHaveTextContent(longAlt);
    expect(container.querySelector('.image-loader__error-alt p')).toHaveAttribute('lang', 'ja');
    expect(container.querySelector('img')).toBeNull();
  });

  it('allows image display with no metadata and handles a subsequent broken DOM image', async () => {
    const { container } = renderImage({ src: '/good-image.jpg', alt: 'The first image' });

    await waitFor(() => expect(container.querySelector('img')).toBeInTheDocument());
    fireEvent.error(container.querySelector('img'));
    expect(screen.getByRole('status')).toHaveTextContent('取得できませんでした');
    expect(container.querySelector('img')).toBeNull();
  });

  it('does not turn a valid original into an error merely because its preview is unavailable', async () => {
    const { container } = renderImage({
      src: '/good-original.jpg',
      previewSrc: '/missing-preview.jpg',
      width: 120,
      height: 90,
      alt: 'Image description',
    });

    await waitFor(() => expect(container.querySelector('img')).toBeInTheDocument());
    expect(container.querySelector('.image-loader__error')).toBeNull();
  });
});
