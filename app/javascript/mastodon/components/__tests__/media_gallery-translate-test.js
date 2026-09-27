/* eslint-disable react/prop-types */

import { render } from '@testing-library/react';
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
