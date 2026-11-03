/* eslint-disable react/prop-types */

import { act, render } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';

jest.mock('../../initial_state', () => ({
  displayMedia: 'show_all',
  autoPlayMedia: false,
  cropImages: true,
  useBlurhash: false,
  useLowResolutionThumbnails: false,
  maxAttachments: 4,
}));

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = {
    formatMessage: ({ defaultMessage }) => defaultMessage,
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

jest.mock('mastodon/components/blurhash', () => () => null);
jest.mock('mastodon/components/thumbhash', () => () => null);
jest.mock('mastodon/components/alt_text_badge', () => ({ description, mode, originalDescription, translatedDescription, sourceLang, targetLang }) => (
  <span data-mode={mode || ''} data-original={originalDescription || ''} data-translated={translatedDescription || ''} data-source-lang={sourceLang || ''} data-target-lang={targetLang || ''}>{description}</span>
));

import MediaGallery from '../media_gallery';

const attachment = (translation) => fromJS({
  id: 'm1',
  type: 'image',
  url: 'https://example.test/cat.jpg',
  preview_url: 'https://example.test/cat-small.jpg',
  remote_url: 'https://example.test/cat.jpg',
  description: 'a cat',
  translation,
  meta: {
    small: { width: 100 },
    original: { width: 200 },
    focus: { x: 0, y: 0 },
  },
});

const renderGallery = (media, props = {}) => render(
  <MediaGallery
    media={fromJS([media])}
    height={110}
    visible
    defaultWidth={300}
    onOpenMedia={jest.fn()}
    lang='ja'
    {...props}
  />,
);

describe('MediaGallery translated descriptions', () => {
  it('uses the translated description for the image alt text', () => {
    const { container } = renderGallery(attachment({ description: 'ねこ' }));
    const image = container.querySelector('img');

    expect(image.getAttribute('alt')).toBe('ねこ');
    expect(image.getAttribute('title')).toBe('ねこ');
    expect(image.getAttribute('lang')).toBe('ja');
  });

  it('falls back to the original description when the translation is removed', () => {
    const { container } = renderGallery(attachment(undefined));

    expect(container.querySelector('img').getAttribute('alt')).toBe('a cat');
  });

  it('follows the explicit view mode for alt text and the badge', () => {
    const media = attachment({ description: 'ねこ' });

    const original = renderGallery(media, { translationMode: 'original', sourceLang: 'en', targetLang: 'ja' });
    expect(original.container.querySelector('img').getAttribute('alt')).toBe('a cat');
    expect(original.container.querySelector('img').getAttribute('lang')).toBe('en');
    expect(original.container.querySelector('[data-mode="original"]').getAttribute('data-original')).toBe('a cat');

    original.unmount();
    const translated = renderGallery(media, { translationMode: 'translated', sourceLang: 'en', targetLang: 'ja' });
    expect(translated.container.querySelector('img').getAttribute('alt')).toBe('ねこ');
    expect(translated.container.querySelector('img').getAttribute('lang')).toBe('ja');

    translated.unmount();
    const bilingual = renderGallery(media, { translationMode: 'bilingual', sourceLang: 'en', targetLang: 'ja' });
    const badge = bilingual.container.querySelector('[data-mode="bilingual"]');
    expect(bilingual.container.querySelector('img').getAttribute('alt')).toBe('ねこ');
    expect(bilingual.container.querySelector('img').getAttribute('lang')).toBe('ja');
    expect(badge.getAttribute('data-original')).toBe('a cat');
    expect(badge.getAttribute('data-translated')).toBe('ねこ');
    expect(badge.getAttribute('data-source-lang')).toBe('en');
    expect(badge.getAttribute('data-target-lang')).toBe('ja');
  });

  it('falls back to the original alt text when the translated description is empty', () => {
    const { container } = renderGallery(attachment({ description: '' }), {
      translationMode: 'bilingual',
      sourceLang: 'en',
      targetLang: 'ja',
    });

    expect(container.querySelector('img').getAttribute('alt')).toBe('a cat');
    expect(container.querySelector('img').getAttribute('lang')).toBe('en');
  });
});

describe('independent card gallery image cropping', () => {
  const portrait = attachment(undefined).setIn(['meta', 'small', 'aspect'], 0.5);

  it('keeps ordinary timeline galleries on the existing crop setting by default', () => {
    const { container } = renderGallery(portrait);
    expect(Number(container.querySelector('.media-gallery').style.aspectRatio)).toBeCloseTo(16 / 9);
  });

  it('uses original aspect ratio for cards with cropping disabled, without changing standard posts', () => {
    const { container, rerender } = renderGallery(portrait, { cropImages: false });
    expect(Number(container.querySelector('.media-gallery').style.aspectRatio)).toBeCloseTo(0.5);

    rerender(
      <MediaGallery media={fromJS([portrait])} height={110} visible defaultWidth={300} onOpenMedia={jest.fn()} cropImages />,
    );
    expect(Number(container.querySelector('.media-gallery').style.aspectRatio)).toBeCloseTo(16 / 9);
  });

  it('keeps standalone post-detail images uncropped even with card cropping enabled', () => {
    const { container } = renderGallery(portrait, { standalone: true, cropImages: true });
    expect(Number(container.querySelector('.media-gallery').style.aspectRatio)).toBeCloseTo(0.5);
  });
});

describe('gallery crop at first paint and after parent-only width changes', () => {
  const portrait = attachment(undefined).setIn(['meta', 'small', 'aspect'], 0.5);

  it('reserves 16:9 from the very first render when actual and cached widths are unknown', () => {
    const { container } = renderGallery(portrait, { defaultWidth: undefined });
    const gallery = container.querySelector('.media-gallery');

    expect(Number(gallery.style.aspectRatio)).toBeCloseTo(16 / 9);
    expect(gallery.style.height).toBe('');
  });

  it('reserves the uncropped ratio at first render without any width measurement', () => {
    const { container } = renderGallery(portrait, { defaultWidth: undefined, cropImages: false });
    const gallery = container.querySelector('.media-gallery');

    expect(Number(gallery.style.aspectRatio)).toBeCloseTo(0.5);
    expect(gallery.style.height).toBe('');
  });

  it('re-measures when its Masonry cell resizes without a window resize', () => {
    const PreviousObserver = window.ResizeObserver;
    let notifyResize;
    let observer;
    let view;

    window.ResizeObserver = class {
      constructor(callback) {
        notifyResize = callback;
        observer = this;
      }

      observe = jest.fn();
      disconnect = jest.fn();
    };

    try {
      view = renderGallery(portrait, { defaultWidth: undefined });
      const gallery = view.container.querySelector('.media-gallery');
      let measuredWidth = 0;
      Object.defineProperty(gallery, 'offsetWidth', { configurable: true, get: () => measuredWidth });

      expect(Number(gallery.style.aspectRatio)).toBeCloseTo(16 / 9);
      expect(gallery.querySelector('img').getAttribute('sizes')).toBeNull();

      measuredWidth = 240;
      act(() => notifyResize([{ target: gallery, contentRect: { width: measuredWidth } }]));
      expect(gallery.querySelector('img').getAttribute('sizes')).toBe('240px');
      expect(Number(gallery.style.aspectRatio)).toBeCloseTo(16 / 9);

      measuredWidth = 120;
      act(() => notifyResize([{ target: gallery, contentRect: { width: measuredWidth } }]));
      expect(gallery.querySelector('img').getAttribute('sizes')).toBe('120px');
      expect(Number(gallery.style.aspectRatio)).toBeCloseTo(16 / 9);

      view.unmount();
      view = null;
      expect(observer.disconnect).toHaveBeenCalledTimes(1);
    } finally {
      view?.unmount();
      window.ResizeObserver = PreviousObserver;
    }
  });
});
