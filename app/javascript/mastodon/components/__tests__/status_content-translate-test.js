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
  languages: [
    ['en', 'English', 'English'],
    ['ja', 'Japanese', '日本語'],
  ],
}));

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

describe('StatusContent translation', () => {
  it('shows Translate for a public post whose language can be translated', () => {
    renderStatus(buildStatus());

    expect(screen.getByRole('button', { name: 'Translate' })).toBeTruthy();
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

    ['limited', 'mutual', 'personal', 'private', 'direct'].forEach(visibility => {
      rerender(
        <Provider store={store}>
          <StatusContent status={buildStatus({ visibility })} onTranslate={jest.fn()} onClick={jest.fn()} />
        </Provider>,
      );
      expect(screen.queryByRole('button', { name: 'Translate' })).toBeNull();
    });
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
    expect(screen.getByText('Translated from English using DeepL')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Show original' }));
    expect(onTranslate).toHaveBeenCalled();
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
    fireEvent.click(screen.getByRole('button', { name: 'Show original' }));
    expect(onTranslate).toHaveBeenCalled();

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
});
