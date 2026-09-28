/* eslint-disable react/prop-types */

import { render } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

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

jest.mock('mastodon/initial_state', () => ({
  displayMedia: 'show_all',
  autoPlayMedia: false,
  cropImages: true,
  useBlurhash: false,
  useLowResolutionThumbnails: false,
  maxAttachments: 4,
  disableSwiping: true,
}));

jest.mock('mastodon/components/blurhash', () => () => null);
jest.mock('mastodon/components/thumbhash', () => () => null);
jest.mock('mastodon/components/icon', () => () => null);
jest.mock('mastodon/components/icon_button', () => () => null);
jest.mock('mastodon/components/gifv', () => () => null);
jest.mock('mastodon/features/video', () => () => null);
jest.mock('mastodon/features/picture_in_picture/components/footer', () => () => null);
jest.mock('mastodon/blurhash', () => ({ getAverageFromBlurhash: () => '#000000' }));
jest.mock('react-swipeable-views', () => ({ children }) => <div>{children}</div>);
jest.mock('mastodon/features/ui/components/image_loader', () => ({ alt, lang }) => <img alt={alt} lang={lang || ''} />);
jest.mock('mastodon/components/alt_text_badge', () => ({ description, sourceLang, targetLang }) => (
  <span data-source-lang={sourceLang || ''} data-target-lang={targetLang || ''}>{description}</span>
));

import MediaGallery from '../../components/media_gallery';
import MediaModal from '../../features/ui/components/media_modal';
import { attachmentAccessibility, galleryTranslationProps, statusTranslationView } from '../translation_view';

const translatedStatus = (mode, translation) => fromJS({
  id: 's1',
  language: 'ja',
  translationMode: mode,
  translation,
  media_attachments: [],
});

const requestedTranslation = {
  language: 'de',
  detected_source_language: 'en',
  requested_source_language: 'fr',
  requested_target_language: 'ja',
  provider: 'DeepL',
};

const attachment = fromJS({
  id: 'm1',
  type: 'image',
  url: 'https://example.test/cat.jpg',
  preview_url: 'https://example.test/cat-small.jpg',
  remote_url: 'https://example.test/cat.jpg',
  description: 'a cat',
  translation: { description: 'ねこ' },
  meta: {
    small: { width: 100 },
    original: { width: 200, height: 100 },
    focus: { x: 0, y: 0 },
  },
});

describe('requested translation language context', () => {
  it('prefers the requested pair over the detected source for every language consumer', () => {
    const view = statusTranslationView(translatedStatus('translated', requestedTranslation));
    const described = attachmentAccessibility(attachment, view);

    expect(view.sourceLang).toBe('fr');
    expect(view.targetLang).toBe('ja');
    expect(view.mediaLang).toBe('ja');
    expect(galleryTranslationProps(view)).toEqual({
      lang: 'ja',
      translationMode: 'translated',
      sourceLang: 'fr',
      targetLang: 'ja',
    });
    expect(described).toMatchObject({ text: 'ねこ', lang: 'ja' });
  });

  it('uses the requested source for original alt text instead of the detected source', () => {
    const view = statusTranslationView(translatedStatus('original', requestedTranslation));
    const described = attachmentAccessibility(attachment, view);

    expect(view.sourceLang).toBe('fr');
    expect(view.mediaLang).toBe('fr');
    expect(described).toMatchObject({ text: 'a cat', lang: 'fr' });
  });

  it('keeps detected source and response target for a legacy translation', () => {
    const view = statusTranslationView(translatedStatus('translated', {
      language: 'ja',
      detected_source_language: 'en',
      provider: 'DeepL',
    }));

    expect(view.sourceLang).toBe('en');
    expect(view.targetLang).toBe('ja');
    expect(attachmentAccessibility(attachment, view).lang).toBe('ja');
  });

  it('gives MediaGallery the requested source and target', () => {
    const view = statusTranslationView(translatedStatus('bilingual', requestedTranslation));
    const { container } = render(
      <MediaGallery
        media={fromJS([attachment])}
        height={110}
        visible
        defaultWidth={300}
        onOpenMedia={jest.fn()}
        {...galleryTranslationProps(view)}
      />,
    );
    const image = container.querySelector('img');
    const badge = container.querySelector('[data-source-lang]');

    expect(image.getAttribute('alt')).toBe('ねこ');
    expect(image.getAttribute('lang')).toBe('ja');
    expect(badge.getAttribute('data-source-lang')).toBe('fr');
    expect(badge.getAttribute('data-target-lang')).toBe('ja');
  });

  it('opens media with the requested target language', () => {
    const status = translatedStatus('translated', requestedTranslation);
    const store = createStore(() => fromJS({ statuses: {} }).setIn(['statuses', 's1'], status));
    const { container } = render(
      <Provider store={store}>
        <MediaModal
          media={fromJS([attachment])}
          statusId='s1'
          index={0}
          onClose={jest.fn()}
          onChangeBackgroundColor={jest.fn()}
        />
      </Provider>,
    );
    const image = container.querySelector('img');

    expect(image.getAttribute('alt')).toBe('ねこ');
    expect(image.getAttribute('lang')).toBe('ja');
  });

  it('opens original media with the requested source language', () => {
    const status = translatedStatus('original', requestedTranslation);
    const store = createStore(() => fromJS({ statuses: {} }).setIn(['statuses', 's1'], status));
    const { container } = render(
      <Provider store={store}>
        <MediaModal
          media={fromJS([attachment])}
          statusId='s1'
          index={0}
          onClose={jest.fn()}
          onChangeBackgroundColor={jest.fn()}
        />
      </Provider>,
    );

    expect(container.querySelector('img').getAttribute('alt')).toBe('a cat');
    expect(container.querySelector('img').getAttribute('lang')).toBe('fr');
  });
});
