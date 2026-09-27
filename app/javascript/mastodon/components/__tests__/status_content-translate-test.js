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
});
