/* eslint-disable react/prop-types */

import { fireEvent, render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

jest.mock('mastodon/initial_state', () => ({
  me: '1',
  autoPlayEmoji: false,
  disableReactions: false,
  translationPrivateContentAllowed: false,
  languages: [
    ['en', 'English', 'English'],
    ['ja', 'Japanese', '日本語'],
  ],
}));

const initialState = jest.requireMock('mastodon/initial_state');

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = {
    locale: 'ja-JP',
    formatMessage: ({ defaultMessage }, values) => {
      let message = defaultMessage;

      if (values) {
        Object.keys(values).forEach(key => {
          message = message.replace(`{${key}}`, values[key]);
        });
      }

      return message;
    },
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage, values }) => intl.formatMessage({ defaultMessage }, values),
  };
});

jest.mock('mastodon/containers/poll_container', () => () => null);
jest.mock('../permalink', () => ({ children }) => <span>{children}</span>);
jest.mock('mastodon/components/icon', () => () => null);

import { normalizeStatus, normalizeStatusTranslation } from '../../actions/importer/normalizer';
import StatusContent from '../status_content';

const store = createStore(() => fromJS({
  server: {
    translationLanguages: {
      items: {
        en: ['ja'],
        zh: ['ja'],
        und: ['ja'],
      },
    },
  },
}));

const buildStatus = (overrides = {}) => fromJS({
  id: 's1',
  contentHtml: '<p>Hello</p>',
  spoilerHtml: 'secret',
  spoiler_text: '',
  search_index: 'Hello',
  language: 'en',
  visibility: 'public',
  mentions: [],
  account: { id: 'a1' },
  ...overrides,
});

const renderStatus = (status, props = {}) => render(
  <Provider store={store}>
    <StatusContent status={status} onTranslate={jest.fn()} onClick={jest.fn()} {...props} />
  </Provider>,
);

const NON_PUBLIC_VISIBILITIES = ['private', 'direct', 'limited', 'mutual', 'personal'];

describe('StatusContent translation', () => {
  beforeEach(() => {
    initialState.me = '1';
    initialState.translationPrivateContentAllowed = false;
  });

  it('shows Translate for a public post whose language can be translated', () => {
    renderStatus(buildStatus());

    expect(screen.getByRole('button', { name: 'Translate' })).toBeTruthy();
  });

  it('falls back from a regional source language to the provider primary language', () => {
    renderStatus(buildStatus({ language: 'zh-CN', contentHtml: '<p>你好</p>', search_index: '你好' }));

    expect(screen.getByRole('button', { name: 'Translate' })).toBeTruthy();
  });

  it('does not collapse a non-region source subtag into the primary language', () => {
    renderStatus(buildStatus({ language: 'zh-YUE', contentHtml: '<p>你好</p>', search_index: '你好' }));

    expect(screen.queryByRole('button', { name: 'Translate' })).toBeNull();
  });


  it('shows Translate for unlisted posts and hides it for private, direct, empty, and unsupported posts', () => {
    const { rerender } = renderStatus(buildStatus({ visibility: 'unlisted' }));
    expect(screen.getByRole('button', { name: 'Translate' })).toBeTruthy();

    rerender(
      <Provider store={store}>
        <StatusContent status={buildStatus({ visibility: 'private' })} onTranslate={jest.fn()} onClick={jest.fn()} />
      </Provider>,
    );
    expect(screen.queryByRole('button', { name: 'Translate' })).toBeNull();

    rerender(
      <Provider store={store}>
        <StatusContent status={buildStatus({ visibility: 'direct' })} onTranslate={jest.fn()} onClick={jest.fn()} />
      </Provider>,
    );
    expect(screen.queryByRole('button', { name: 'Translate' })).toBeNull();

    rerender(
      <Provider store={store}>
        <StatusContent status={buildStatus({ search_index: '   ' })} onTranslate={jest.fn()} onClick={jest.fn()} />
      </Provider>,
    );
    expect(screen.queryByRole('button', { name: 'Translate' })).toBeNull();

    rerender(
      <Provider store={store}>
        <StatusContent status={buildStatus({ language: 'fr' })} onTranslate={jest.fn()} onClick={jest.fn()} />
      </Provider>,
    );
    expect(screen.queryByRole('button', { name: 'Translate' })).toBeNull();

    NON_PUBLIC_VISIBILITIES.forEach(visibility => {
      rerender(
        <Provider store={store}>
          <StatusContent status={buildStatus({ visibility })} onTranslate={jest.fn()} onClick={jest.fn()} />
        </Provider>,
      );
      expect(screen.queryByRole('button', { name: 'Translate' })).toBeNull();
      expect(screen.queryByRole('button', { name: 'Bilingual' })).toBeNull();
    });
  });

  it('shows Translate and Bilingual for every visibility when private content is allowed', () => {
    initialState.translationPrivateContentAllowed = true;

    ['public', 'unlisted', ...NON_PUBLIC_VISIBILITIES].forEach(visibility => {
      const { unmount } = renderStatus(buildStatus({ visibility }));

      expect(screen.getByRole('button', { name: 'Translate' })).toBeTruthy();
      expect(screen.getByRole('button', { name: 'Bilingual' })).toBeTruthy();
      unmount();
    });
  });

  it('keeps language, content, and login checks when private content is allowed', () => {
    initialState.translationPrivateContentAllowed = true;
    const { rerender } = renderStatus(buildStatus({ visibility: 'direct', language: 'fr' }));
    expect(screen.queryByRole('button', { name: 'Translate' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Bilingual' })).toBeNull();

    rerender(
      <Provider store={store}>
        <StatusContent status={buildStatus({ visibility: 'direct', search_index: '   ' })} onTranslate={jest.fn()} onClick={jest.fn()} />
      </Provider>,
    );
    expect(screen.queryByRole('button', { name: 'Translate' })).toBeNull();

    initialState.me = null;
    rerender(
      <Provider store={store}>
        <StatusContent status={buildStatus({ visibility: 'direct' })} onTranslate={jest.fn()} onClick={jest.fn()} />
      </Provider>,
    );
    expect(screen.queryByRole('button', { name: 'Translate' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Bilingual' })).toBeNull();

    rerender(
      <Provider store={store}>
        <StatusContent status={buildStatus({ visibility: 'public' })} onTranslate={jest.fn()} onClick={jest.fn()} />
      </Provider>,
    );
    expect(screen.queryByRole('button', { name: 'Translate' })).toBeNull();
  });

  it('renders translated content and CW, then offers Show original', () => {
    const onTranslate = jest.fn();
    const status = buildStatus({
      spoiler_text: 'secret',
      translation: {
        contentHtml: '<p>こんにちは</p>',
        spoilerHtml: '秘密',
        spoiler_text: '秘密',
        language: 'ja',
        detected_source_language: 'en',
        provider: 'DeepL',
      },
    });

    const { container } = render(
      <Provider store={store}>
        <StatusContent status={status} onTranslate={onTranslate} onClick={jest.fn()} />
      </Provider>,
    );

    expect(container.querySelector('.status__content__text').innerHTML).toContain('こんにちは');
    expect(container.querySelector('.translate').innerHTML).toContain('秘密');
    expect(screen.getByText('English → 日本語 · DeepL')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Translated', pressed: true })).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Original' }));
    expect(onTranslate).toHaveBeenCalledWith('original');
    expect(container.querySelector('.status__content__text').innerHTML).toContain('こんにちは');
  });

  it('shows a CW-only translation as the body and restores the original text', () => {
    const normalized = fromJS(normalizeStatus({
      id: 's1',
      account: { id: 'a1', acct: 'alice' },
      content: '',
      spoiler_text: 'secret warning',
      emojis: [],
      media_attachments: [],
      mentions: [],
      visibility: 'public',
      sensitive: false,
      language: 'en',
      url: 'https://example.test/1',
      uri: 'https://example.test/1',
      updated_at: '2020-01-01T00:00:00.000Z',
      quote: null,
    }, null, ''));

    expect(normalized.get('spoiler_text')).toBe('');
    expect(normalized.get('content')).toBe('secret warning');
    expect(normalized.get('search_index')).toContain('secret warning');

    const translation = normalizeStatusTranslation({
      content: '',
      spoiler_text: '秘密の警告',
      detected_source_language: 'en',
      language: 'ja',
      provider: 'DeepL',
    }, normalized, '');

    expect(translation.spoiler_text).toBe('');
    expect(translation.contentHtml).toContain('秘密の警告');

    const onTranslate = jest.fn();
    const { container, rerender } = render(
      <Provider store={store}>
        <StatusContent status={normalized.set('translation', fromJS(translation))} onTranslate={onTranslate} />
      </Provider>,
    );

    const translatedBody = container.querySelector('.status__content__text').textContent;
    expect(translatedBody).toContain('秘密の警告');
    expect(translatedBody.trim()).not.toBe('');
    fireEvent.click(screen.getByRole('button', { name: 'Original' }));
    expect(onTranslate).toHaveBeenCalledWith('original');

    rerender(
      <Provider store={store}>
        <StatusContent status={normalized} onTranslate={onTranslate} />
      </Provider>,
    );

    expect(container.querySelector('.status__content__text').textContent).toContain('secret warning');
    expect(screen.queryByText('秘密の警告')).toBeNull();
    expect(screen.getByRole('button', { name: 'Translate' })).toBeTruthy();
  });

  it('keeps a content warning and body as separate translated fields', () => {
    const status = fromJS({
      spoiler_text: 'cw',
      content: '<p>Hello</p>',
      emojis: [],
    });
    const translation = normalizeStatusTranslation({
      content: '<p>こんにちは</p>',
      spoiler_text: '警告',
      detected_source_language: 'en',
      language: 'ja',
      provider: 'DeepL',
    }, status, '');

    expect(translation.spoiler_text).toBe('警告');
    expect(translation.contentHtml).toContain('こんにちは');
    expect(translation.spoilerHtml).toContain('警告');
  });

  it('shows Translate and Bilingual, with the preferred action first', () => {
    const { container, rerender } = renderStatus(buildStatus());
    let buttons = container.querySelectorAll('.status__content__translate-button');

    expect(buttons).toHaveLength(2);
    expect(buttons[0].textContent).toBe('Translate');
    expect(buttons[0].className).toContain('status__content__translate-button--primary');
    expect(buttons[1].textContent).toBe('Bilingual');
    expect(buttons[1].className).toContain('status__content__translate-button--secondary');

    const onTranslate = jest.fn();
    rerender(
      <Provider store={store}>
        <StatusContent status={buildStatus()} onTranslate={onTranslate} onClick={jest.fn()} translationPreferredMode='bilingual' />
      </Provider>,
    );

    buttons = container.querySelectorAll('.status__content__translate-button');
    expect(buttons[0].textContent).toBe('Bilingual');
    expect(buttons[0].className).toContain('status__content__translate-button--primary');
    expect(buttons[1].textContent).toBe('Translate');
    fireEvent.click(buttons[0]);
    fireEvent.click(buttons[1]);
    expect(onTranslate).toHaveBeenNthCalledWith(1, 'bilingual');
    expect(onTranslate).toHaveBeenNthCalledWith(2, 'translated');
  });

  it('switches loaded translations without asking the component to fetch again', () => {
    const onTranslate = jest.fn();
    const status = buildStatus({
      translationMode: 'translated',
      translation: {
        contentHtml: '<p>こんにちは</p>',
        spoilerHtml: '',
        language: 'ja',
        detected_source_language: 'en',
        provider: 'LibreTranslate',
      },
    });

    render(
      <Provider store={store}>
        <StatusContent status={status} onTranslate={onTranslate} onClick={jest.fn()} />
      </Provider>,
    );

    fireEvent.click(screen.getByRole('button', { name: 'Bilingual' }));
    fireEvent.click(screen.getByRole('button', { name: 'Translated' }));
    fireEvent.click(screen.getByRole('button', { name: 'Original' }));

    expect(onTranslate.mock.calls.map(call => call[0])).toEqual(['bilingual', 'translated', 'original']);
  });

  it('pairs matching paragraphs and marks source and target languages', () => {
    const status = buildStatus({
      language: 'de',
      contentHtml: '<p>Eins</p><p>Zwei</p><p>Drei</p>',
      translationMode: 'bilingual',
      translation: {
        contentHtml: '<p>一</p><p>二</p><p>三</p>',
        spoilerHtml: '',
        language: 'ja',
        detected_source_language: 'de',
        provider: 'DeepL',
      },
    });
    const { container } = renderStatus(status);
    const pairs = container.querySelectorAll('.status-translation-pair');

    expect(pairs).toHaveLength(3);
    expect(pairs[0].querySelector('.status-translation-pair__source p').getAttribute('lang')).toBe('de');
    expect(pairs[0].querySelector('.status-translation-pair__target p').getAttribute('lang')).toBe('ja');
    expect(pairs[0].querySelector('.status-translation-pair__source').className).toContain('status-translation-pair__source');
    expect(pairs[1].querySelector('.status-translation-pair__target').textContent).toBe('二');
    expect(pairs[2].querySelector('.status-translation-pair__source').textContent).toBe('Drei');
  });

  it('falls back to one pair when block structure does not match', () => {
    const status = buildStatus({
      language: 'de',
      contentHtml: '<p>Eins</p><p>Zwei</p>',
      translationMode: 'bilingual',
      translation: {
        contentHtml: '<p>一</p><blockquote><p>二</p></blockquote>',
        spoilerHtml: '',
        language: 'ja',
        detected_source_language: 'de',
        provider: 'DeepL',
      },
    });
    const { container } = renderStatus(status);
    const pairs = container.querySelectorAll('.status-translation-pair');
    const source = pairs[0].querySelector('.status-translation-pair__source');
    const target = pairs[0].querySelector('.status-translation-pair__target');

    expect(pairs).toHaveLength(1);
    expect(source.textContent).toContain('Eins');
    expect(source.textContent).toContain('Zwei');
    expect(target.textContent).toContain('一');
    expect(target.textContent).toContain('二');
    expect(source.querySelector('[lang="de"]')).toBeTruthy();
    expect(source.querySelector('p').getAttribute('lang')).toBe('de');
    expect(target.querySelector('p').getAttribute('lang')).toBe('ja');
    expect(target.querySelector('blockquote').getAttribute('lang')).toBe('ja');
  });

  it('omits a translated block whose visible text matches the source', () => {
    const status = buildStatus({
      contentHtml: '<p>Hello</p><p>#tag</p>',
      translationMode: 'bilingual',
      translation: {
        contentHtml: '<p>こんにちは</p><p>#tag</p>',
        spoilerHtml: '',
        language: 'ja',
        detected_source_language: 'en',
        provider: 'DeepL',
      },
    });
    const { container } = renderStatus(status);
    const pairs = container.querySelectorAll('.status-translation-pair');

    expect(pairs[0].querySelector('.status-translation-pair__target').textContent).toBe('こんにちは');
    expect(pairs[1].querySelector('.status-translation-pair__source').textContent).toBe('#tag');
    expect(pairs[1].querySelector('.status-translation-pair__target')).toBeNull();
  });

  it('shows the source and target content warnings together with one toggle', () => {
    const status = buildStatus({
      spoiler_text: 'secret',
      spoilerHtml: 'secret',
      contentHtml: '<p>Hello</p>',
      translationMode: 'bilingual',
      translation: {
        contentHtml: '<p>こんにちは</p>',
        spoilerHtml: '秘密',
        spoiler_text: '秘密',
        language: 'ja',
        detected_source_language: 'en',
        provider: 'DeepL',
      },
    });
    const { container } = renderStatus(status);
    const spoiler = container.querySelector('.status__content p');

    expect(spoiler.querySelector('.status-translation-pair__source').textContent).toBe('secret');
    expect(spoiler.querySelector('.status-translation-pair__source').getAttribute('lang')).toBe('en');
    expect(spoiler.querySelector('.status-translation-pair__target').textContent).toBe('秘密');
    expect(spoiler.querySelector('.status-translation-pair__target').getAttribute('lang')).toBe('ja');
    expect(screen.getAllByRole('button', { name: 'Show more' })).toHaveLength(1);
    expect(screen.queryByRole('button', { name: 'Show less' })).toBeNull();
  });
});
