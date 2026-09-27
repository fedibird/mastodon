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
jest.mock('mastodon/components/alt_text_badge', () => ({ description }) => <span>{description}</span>);

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

const renderGallery = (media) => render(
  <MediaGallery
    media={fromJS([media])}
    height={110}
    visible
    defaultWidth={300}
    onOpenMedia={jest.fn()}
    lang='ja'
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
});
