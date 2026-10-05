/* eslint-disable react/prop-types */

import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

jest.mock('mastodon/initial_state', () => ({
  me: '1',
  autoPlayEmoji: false,
  disableReactions: false,
  translationPrivateContentAllowed: false,
  translationBarVisibility: 'always',
  translationPreferredMode: 'both',
  languages: [
    ['en', 'English', 'English'],
    ['ja', 'Japanese', '日本語'],
    ['fr', 'French', 'Français'],
  ],
}));

jest.mock('react-overlays/Overlay', () => {
  return ({ show, children }) => (show ? children({ props: { style: {} }, placement: 'bottom' }) : null);
});

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

import { readFileSync } from 'fs';
import { resolve } from 'path';

import { STATUS_IMPORT } from '../../actions/importer';
import { normalizeStatus, normalizeStatusTranslation } from '../../actions/importer/normalizer';
import statusesReducer from '../../reducers/statuses';
import translationAssumptions from '../../reducers/translation_assumptions';
import StatusContent from '../status_content';

const createTranslationStore = items => createStore(() => fromJS({
  server: {
    translationLanguages: {
      items,
    },
  },
}));

const store = createTranslationStore({
  en: ['ja'],
  zh: ['ja'],
  und: ['ja'],
});

const CHINESE_SCRIPT_LANGUAGES = {
  'zh-Hans': ['ja'],
  'zh-Hant': ['ja'],
  und: ['ja'],
};

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

const renderStatus = (status, props = {}, languages) => render(
  <Provider store={languages ? createTranslationStore(languages) : store}>
    <StatusContent status={status} onTranslate={jest.fn()} onClick={jest.fn()} {...props} />
  </Provider>,
);

const NON_PUBLIC_VISIBILITIES = ['private', 'direct', 'limited', 'mutual', 'personal'];

const expectUnsupportedPair = () => {
  expect(screen.getByRole('button', { name: 'Translate' })).toBeDisabled();
  expect(screen.getByRole('button', { name: 'Bilingual' })).toBeDisabled();
  expect(screen.getByText('This language pair is not supported.')).toBeTruthy();
  expect(screen.queryByText('Choose Simplified Chinese or Traditional Chinese as the source language.')).toBeNull();
};

const interactiveReducer = (state = fromJS({
  server: {
    translationLanguages: {
      items: {
        en: ['ja'],
        fr: ['ja'],
        und: ['ja'],
      },
    },
  },
  statuses: {},
  translation_assumptions: {},
}), action) => state
  .set('statuses', statusesReducer(state.get('statuses'), action))
  .set('translation_assumptions', translationAssumptions(state.get('translation_assumptions'), action));

describe('StatusContent translation', () => {
  beforeEach(() => {
    initialState.me = '1';
    initialState.translationPrivateContentAllowed = false;
    initialState.translationBarVisibility = 'always';
    initialState.translationPreferredMode = 'both';
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

    expectUnsupportedPair();
  });

  describe('Chinese script provider languages', () => {
    const chineseStatus = language => buildStatus({
      language,
      contentHtml: '<p>你好</p>',
      search_index: '你好',
    });

    it('keeps bare zh unresolved instead of using und auto-detection', () => {
      renderStatus(chineseStatus('zh'), {}, CHINESE_SCRIPT_LANGUAGES);

      expect(screen.getByRole('button', { name: 'Source language, zh' })).toBeTruthy();
      expect(screen.getByRole('button', { name: 'Translate' })).toBeDisabled();
      expect(screen.getByRole('button', { name: 'Bilingual' })).toBeDisabled();
      expect(screen.getByText('Choose Simplified Chinese or Traditional Chinese as the source language.')).toBeTruthy();
      expect(screen.queryByText('This language pair is not supported.')).toBeNull();
    });

    it('shows Translate for zh-CN by using zh-Hans', () => {
      renderStatus(chineseStatus('zh-CN'), {}, CHINESE_SCRIPT_LANGUAGES);

      expect(screen.getByRole('button', { name: 'Translate' })).toBeTruthy();
    });

    it('shows Translate for zh-TW by using zh-Hant', () => {
      renderStatus(chineseStatus('zh-TW'), {}, CHINESE_SCRIPT_LANGUAGES);

      expect(screen.getByRole('button', { name: 'Translate' })).toBeTruthy();
    });

    it('shows Translate for the other Chinese region tags', () => {
      ['zh-SG', 'zh-HK', 'zh-MO', 'zh-cn', 'zh_TW', 'zh-hans', 'ZH-HANT'].forEach(language => {
        const { unmount } = renderStatus(chineseStatus(language), {}, CHINESE_SCRIPT_LANGUAGES);

        expect(screen.getByRole('button', { name: 'Translate' })).toBeTruthy();
        unmount();
      });
    });

    it('does not show Translate for zh-YUE when only Chinese script tags are available', () => {
      renderStatus(chineseStatus('zh-YUE'), {}, CHINESE_SCRIPT_LANGUAGES);

      expectUnsupportedPair();
    });

    it('prefers an exact zh key over und auto detection', () => {
      const { unmount } = renderStatus(chineseStatus('zh'), {}, {
        zh: ['ja'],
        'zh-Hans': ['ja'],
        'zh-Hant': ['ja'],
        und: ['ko'],
      });

      expect(screen.getByRole('button', { name: 'Translate' })).toBeTruthy();
      unmount();

      renderStatus(chineseStatus('zh'), {}, {
        zh: ['ko'],
        'zh-Hans': ['ja'],
        'zh-Hant': ['ja'],
        und: ['ja'],
      });

      expectUnsupportedPair();
    });

    it('does not use und for bare zh when no Chinese script tag exists', () => {
      renderStatus(chineseStatus('zh'), {}, {
        en: ['ja'],
        und: ['ja'],
      });

      expectUnsupportedPair();
    });

    it('does not use und for an unsupported language', () => {
      renderStatus(chineseStatus('ko'), {}, CHINESE_SCRIPT_LANGUAGES);

      expectUnsupportedPair();
    });

    it('does not show Translate for zh-CN when zh-Hans is missing', () => {
      renderStatus(chineseStatus('zh-CN'), {}, {
        'zh-Hant': ['ja'],
        und: ['ja'],
      });

      expectUnsupportedPair();
    });
  });

  describe('bare zh source choice', () => {
    const chineseLanguages = {
      en: ['ja', 'zh-Hans'],
      'zh-Hans': ['ja', 'en'],
      'zh-Hant': ['ja', 'en'],
      und: ['ja', 'en'],
    };

    const renderInteractive = () => {
      const status = buildStatus({ language: 'zh', contentHtml: '<p>你好</p>', search_index: '你好' });
      const interactive = createStore(interactiveReducer, fromJS({
        server: { translationLanguages: { items: chineseLanguages } },
        statuses: { s1: status },
        translation_assumptions: {},
      }));

      render(
        <Provider store={interactive}>
          <StatusContent status={status} onTranslate={jest.fn()} onClick={jest.fn()} />
        </Provider>,
      );

      return { status, interactive };
    };

    const optionCodes = () => screen.getAllByRole('option').map(option => option.getAttribute('data-index'));

    const searchFor = (query) => {
      fireEvent.change(screen.getByPlaceholderText('Search languages...'), { target: { value: query } });
    };

    it('asks for a Chinese script, then translates from the chosen script without changing status.language', () => {
      const { status, interactive } = renderInteractive();

      expect(screen.getByRole('button', { name: 'Source language, zh' })).toBeTruthy();
      expect(screen.getByRole('button', { name: 'Translate' })).toBeDisabled();
      expect(screen.getByRole('button', { name: 'Bilingual' })).toBeDisabled();
      expect(screen.getByText('Choose Simplified Chinese or Traditional Chinese as the source language.')).toBeTruthy();
      expect(screen.queryByText('This language pair is not supported.')).toBeNull();
      expect(screen.getByRole('button', { name: 'Translate' })).toHaveAttribute('title', 'Choose Simplified Chinese or Traditional Chinese as the source language.');
      expect(screen.getByRole('button', { name: 'Translate' })).toHaveAttribute('aria-describedby', 'translation-pair-s1');

      fireEvent.click(screen.getByRole('button', { name: 'Source language, zh' }));

      expect(optionCodes().slice(0, 3)).toEqual(['zh', 'zh-Hans', 'zh-Hant']);
      expect(screen.getByRole('option', { name: '简体中文 (簡体中国語)' })).toBeTruthy();
      expect(screen.getByRole('option', { name: '繁體中文 (繁体中国語)' })).toBeTruthy();

      ['zh-Hans', 'zh-Hant', 'Simplified', 'Traditional', '简体中文', '繁體中文', 'Chinese'].forEach(query => {
        searchFor(query);
        expect(screen.getAllByRole('option').length).toBeGreaterThan(0);
        expect(optionCodes().some(code => code === 'zh-Hans' || code === 'zh-Hant')).toBe(true);
      });

      searchFor('Simplified');
      fireEvent.click(screen.getByRole('option', { name: /简体中文/ }));

      expect(screen.getByRole('button', { name: 'Source language, 简体中文' })).toBeTruthy();
      expect(screen.getByRole('button', { name: 'Translate' })).toBeEnabled();
      expect(screen.getByRole('button', { name: 'Bilingual' })).toBeEnabled();
      expect(screen.queryByText('Choose Simplified Chinese or Traditional Chinese as the source language.')).toBeNull();
      expect(screen.queryByText('This language pair is not supported.')).toBeNull();
      expect(interactive.getState().getIn(['translation_assumptions', 's1'])).toBe('zh-Hans');
      expect(interactive.getState().getIn(['statuses', 's1', 'language'])).toBe('zh');
      expect(status.get('language')).toBe('zh');

      interactive.dispatch({
        type: STATUS_IMPORT,
        status: { id: 's1', language: 'zh', contentHtml: '<p>你好</p>', search_index: '你好', visibility: 'public' },
      });

      expect(interactive.getState().getIn(['translation_assumptions', 's1'])).toBe('zh-Hans');
      expect(interactive.getState().getIn(['statuses', 's1', 'language'])).toBe('zh');
      expect(screen.getByRole('button', { name: 'Source language, 简体中文' })).toBeTruthy();
      expect(screen.getByRole('button', { name: 'Translate' })).toBeEnabled();
    });

    it('enables translation after Traditional Chinese is chosen', () => {
      const { status, interactive } = renderInteractive();

      fireEvent.click(screen.getByRole('button', { name: 'Source language, zh' }));
      fireEvent.click(screen.getByRole('option', { name: /繁體中文/ }));

      expect(screen.getByRole('button', { name: 'Source language, 繁體中文' })).toBeTruthy();
      expect(screen.getByRole('button', { name: 'Translate' })).toBeEnabled();
      expect(interactive.getState().getIn(['translation_assumptions', 's1'])).toBe('zh-Hant');
      expect(status.get('language')).toBe('zh');
      expect(screen.queryByText('Choose Simplified Chinese or Traditional Chinese as the source language.')).toBeNull();
    });

    it('uses provider auto detection only when und is chosen explicitly', () => {
      const { status, interactive } = renderInteractive();

      fireEvent.click(screen.getByRole('button', { name: 'Source language, zh' }));
      fireEvent.click(screen.getByRole('option', { name: /Unspecified/ }));

      expect(screen.getByRole('button', { name: 'Source language, Unspecified' })).toBeTruthy();
      expect(screen.getByRole('button', { name: 'Translate' })).toBeEnabled();
      expect(interactive.getState().getIn(['translation_assumptions', 's1'])).toBe('und');
      expect(status.get('language')).toBe('zh');
      expect(screen.queryByText('Choose Simplified Chinese or Traditional Chinese as the source language.')).toBeNull();
      expect(screen.queryByText('This language pair is not supported.')).toBeNull();
    });

    it('translates bare zh normally when the provider has generic zh', () => {
      renderStatus(buildStatus({ language: 'zh', contentHtml: '<p>你好</p>', search_index: '你好' }), {}, {
        zh: ['ja', 'en'],
        'zh-Hans': ['ja'],
        'zh-Hant': ['ja'],
        und: ['ja'],
      });

      expect(screen.getByRole('button', { name: 'Translate' })).toBeEnabled();
      expect(screen.getByRole('button', { name: 'Bilingual' })).toBeEnabled();
      expect(screen.queryByText('Choose Simplified Chinese or Traditional Chinese as the source language.')).toBeNull();
      expect(screen.queryByText('This language pair is not supported.')).toBeNull();
    });

    it('shows Simplified Chinese in the target picker', () => {
      renderStatus(buildStatus(), {}, { en: ['ja', 'zh-Hans'], und: ['ja'] });

      fireEvent.click(screen.getByRole('button', { name: 'Target language, 日本語' }));

      expect(screen.getByRole('option', { name: '简体中文 (簡体中国語)' })).toBeTruthy();
    });

    it('shows guidance when only one Chinese script supports the current target', () => {
      renderStatus(buildStatus({ language: 'zh', contentHtml: '<p>你好</p>', search_index: '你好' }), {}, {
        'zh-Hans': ['ja'],
        'zh-Hant': ['en'],
        und: ['en'],
      });

      expect(screen.getByRole('button', { name: 'Translate' })).toBeDisabled();
      expect(screen.getByRole('button', { name: 'Bilingual' })).toBeDisabled();
      expect(screen.getByText('Choose Simplified Chinese or Traditional Chinese as the source language.')).toBeTruthy();
      expect(screen.queryByText('This language pair is not supported.')).toBeNull();
    });

    it('uses the generic unsupported warning when neither script can reach the current target', () => {
      const status = buildStatus({ language: 'zh', contentHtml: '<p>你好</p>', search_index: '你好' });
      const interactive = createStore(interactiveReducer, fromJS({
        server: {
          translationLanguages: {
            items: {
              'zh-Hans': ['ja'],
              'zh-Hant': ['ja'],
              und: ['ja'],
            },
          },
        },
        statuses: { s1: status },
        translation_assumptions: {},
        settings: { translation: { targetLanguage: 'de' } },
      }));

      render(
        <Provider store={interactive}>
          <StatusContent status={status} onTranslate={jest.fn()} onClick={jest.fn()} />
        </Provider>,
      );

      expect(screen.getByRole('button', { name: 'Target language, de' })).toBeTruthy();
      expect(screen.getByRole('button', { name: 'Translate' })).toBeDisabled();
      expect(screen.getByRole('button', { name: 'Bilingual' })).toBeDisabled();
      expect(screen.getByText('This language pair is not supported.')).toBeTruthy();
      expect(screen.queryByText('Choose Simplified Chinese or Traditional Chinese as the source language.')).toBeNull();
      expect(screen.getByRole('button', { name: 'Translate' })).toHaveAttribute('title', 'This language pair is not supported.');
    });

    it('stays quiet for a same-language bare zh pair', () => {
      const status = buildStatus({ language: 'zh', contentHtml: '<p>你好</p>', search_index: '你好' });
      const interactive = createStore(interactiveReducer, fromJS({
        server: {
          translationLanguages: {
            items: {
              'zh-Hans': ['ja'],
              'zh-Hant': ['ja'],
              und: ['ja'],
            },
          },
        },
        statuses: { s1: status },
        translation_assumptions: {},
        settings: { translation: { targetLanguage: 'zh' } },
      }));

      render(
        <Provider store={interactive}>
          <StatusContent status={status} onTranslate={jest.fn()} onClick={jest.fn()} />
        </Provider>,
      );

      const translate = screen.getByRole('button', { name: 'Translate' });
      const bilingual = screen.getByRole('button', { name: 'Bilingual' });

      expect(translate).toBeDisabled();
      expect(bilingual).toBeDisabled();
      expect(screen.queryByText('Choose Simplified Chinese or Traditional Chinese as the source language.')).toBeNull();
      expect(screen.queryByText('This language pair is not supported.')).toBeNull();
      expect(translate).not.toHaveAttribute('title');
      expect(translate).not.toHaveAttribute('aria-describedby');
      expect(bilingual).not.toHaveAttribute('title');
      expect(bilingual).not.toHaveAttribute('aria-describedby');
    });

    it.each([
      ['translated', ['Translate']],
      ['bilingual', ['Bilingual']],
      ['both', ['Translate', 'Bilingual']],
    ])('keeps Chinese guidance on the %s request buttons', (preferredMode, names) => {
      renderStatus(buildStatus({ language: 'zh', contentHtml: '<p>你好</p>', search_index: '你好' }), { translationPreferredMode: preferredMode }, CHINESE_SCRIPT_LANGUAGES);
      const guidance = 'Choose Simplified Chinese or Traditional Chinese as the source language.';

      names.forEach(name => {
        const button = screen.getByRole('button', { name });

        expect(button).toBeDisabled();
        expect(button).toHaveAttribute('title', guidance);
        expect(button).toHaveAttribute('aria-describedby', 'translation-pair-s1');
      });
      expect(screen.queryByRole('button', { name: 'Translate' }) === null).toBe(!names.includes('Translate'));
      expect(screen.queryByRole('button', { name: 'Bilingual' }) === null).toBe(!names.includes('Bilingual'));
      expect(screen.getByText(guidance)).toBeTruthy();
      expect(screen.queryByText('This language pair is not supported.')).toBeNull();
    });
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
    expectUnsupportedPair();

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

  it('shows Translate and Bilingual for the viewer own personal post when private content is not allowed', () => {
    renderStatus(buildStatus({
      visibility: 'personal',
      account: { id: '1' },
    }));

    expect(screen.getByRole('button', { name: 'Translate' })).toBeEnabled();
    expect(screen.getByRole('button', { name: 'Bilingual' })).toBeEnabled();
  });

  it('hides translation for another account personal post, a personal boost of someone else, and the viewer own private visibilities', () => {
    const { rerender } = renderStatus(buildStatus({
      visibility: 'personal',
      account: { id: '2' },
    }));
    expect(screen.queryByRole('button', { name: 'Translate' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Bilingual' })).toBeNull();

    rerender(
      <Provider store={store}>
        <StatusContent
          status={buildStatus({
            visibility: 'personal',
            account: { id: '1' },
            reblog: { id: 's2', account: { id: '9' }, visibility: 'public' },
          })}
          onTranslate={jest.fn()}
          onClick={jest.fn()}
        />
      </Provider>,
    );
    expect(screen.queryByRole('button', { name: 'Translate' })).toBeNull();

    rerender(
      <Provider store={store}>
        <StatusContent
          status={buildStatus({
            visibility: 'personal',
            account: { id: '1' },
            reblog: { id: 's3', account: { id: '1' }, visibility: 'public' },
          })}
          onTranslate={jest.fn()}
          onClick={jest.fn()}
        />
      </Provider>,
    );
    expect(screen.getByRole('button', { name: 'Translate' })).toBeEnabled();
    expect(screen.getByRole('button', { name: 'Bilingual' })).toBeEnabled();

    ['private', 'direct', 'limited', 'mutual'].forEach(visibility => {
      rerender(
        <Provider store={store}>
          <StatusContent status={buildStatus({ visibility, account: { id: '1' } })} onTranslate={jest.fn()} onClick={jest.fn()} />
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
    expectUnsupportedPair();

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
    expect(screen.getByRole('button', { name: 'Source language, English' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Target language, 日本語' })).toBeTruthy();
    expect(screen.queryByText('Detected English')).toBeNull();
    expect(screen.getByText('· DeepL')).toBeTruthy();
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

  it('shows only the configured request action before a translation exists', () => {
    const { container, rerender } = renderStatus(buildStatus(), { translationPreferredMode: 'translated' });
    let buttons = container.querySelectorAll('.status__content__translate-button');

    expect(buttons).toHaveLength(1);
    expect(buttons[0].textContent).toBe('Translate');
    expect(buttons[0].className).toContain('status__content__translate-button--primary');
    expect(screen.queryByRole('button', { name: 'Bilingual' })).toBeNull();

    rerender(
      <Provider store={store}>
        <StatusContent status={buildStatus()} onTranslate={jest.fn()} onClick={jest.fn()} translationPreferredMode='bilingual' />
      </Provider>,
    );

    buttons = container.querySelectorAll('.status__content__translate-button');
    expect(buttons).toHaveLength(1);
    expect(buttons[0].textContent).toBe('Bilingual');
    expect(buttons[0].className).toContain('status__content__translate-button--primary');
    expect(screen.queryByRole('button', { name: 'Translate' })).toBeNull();

    rerender(
      <Provider store={store}>
        <StatusContent status={buildStatus()} onTranslate={jest.fn()} onClick={jest.fn()} translationPreferredMode='both' />
      </Provider>,
    );

    buttons = container.querySelectorAll('.status__content__translate-button');
    expect(Array.from(buttons).map(button => button.textContent)).toEqual(['Translate', 'Bilingual']);
    expect(buttons[0].className).not.toContain('status__content__translate-button--primary');
    expect(buttons[1].className).not.toContain('status__content__translate-button--primary');
  });

  it('attaches the unsupported warning to the request button that is shown', () => {
    renderStatus(buildStatus({ language: 'fr' }), { translationPreferredMode: 'translated' });
    const translate = screen.getByRole('button', { name: 'Translate' });

    expect(translate).toBeDisabled();
    expect(translate).toHaveAttribute('title', 'This language pair is not supported.');
    expect(translate).toHaveAttribute('aria-describedby', 'translation-pair-s1');
    expect(screen.queryByRole('button', { name: 'Bilingual' })).toBeNull();
    expect(screen.getByText('This language pair is not supported.')).toBeTruthy();
  });

  it.each(['translated', 'bilingual', 'both'])('shows every display mode after translation when the preference is %s', (preferredMode) => {
    const onTranslate = jest.fn();

    renderStatus(buildStatus({
      translationMode: 'translated',
      translation: {
        contentHtml: '<p>こんにちは</p>',
        spoilerHtml: '',
        language: 'ja',
        detected_source_language: 'en',
        requested_source_language: 'en',
        requested_target_language: 'ja',
        provider: 'LibreTranslate',
      },
    }), { translationPreferredMode: preferredMode, onTranslate });

    expect(screen.getByRole('button', { name: 'Original' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Translated' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Bilingual' })).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Translate' })).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: 'Bilingual' }));
    fireEvent.click(screen.getByRole('button', { name: 'Original' }));
    expect(onTranslate.mock.calls.map(call => call[0])).toEqual(['bilingual', 'original']);
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

  it('keeps the language bar without an unsupported notice before languages load', () => {
    const emptyStore = createStore(() => fromJS({
      server: {
        translationLanguages: {},
      },
    }));

    render(
      <Provider store={emptyStore}>
        <StatusContent status={buildStatus()} onTranslate={jest.fn()} onClick={jest.fn()} />
      </Provider>,
    );

    expect(document.querySelector('.status__translation-bar')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Source language, English' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Target language, 日本語' })).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Translate' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Bilingual' })).toBeNull();
    expect(screen.queryByText('This language pair is not supported.')).toBeNull();
  });

  it('uses the requested pair for content language and keeps detection as metadata', () => {
    const { container } = renderStatus(buildStatus({
      language: 'fr',
      contentHtml: '<p>Hello</p>',
      translationMode: 'bilingual',
      translation: {
        contentHtml: '<p>こんにちは</p>',
        spoilerHtml: '',
        language: 'de',
        detected_source_language: 'en',
        requested_source_language: 'fr',
        requested_target_language: 'ja',
        provider: 'DeepL',
      },
    }));
    const pair = container.querySelector('.status-translation-pair');

    expect(pair.querySelector('.status-translation-pair__source p').getAttribute('lang')).toBe('fr');
    expect(pair.querySelector('.status-translation-pair__target p').getAttribute('lang')).toBe('ja');
    expect(screen.getByRole('button', { name: 'Source language, Français' })).toBeTruthy();
    expect(screen.getByText('Detected English')).toBeTruthy();
  });

  it('hides the translation bar when the setting is off', () => {
    initialState.translationBarVisibility = 'never';
    renderStatus(buildStatus());

    expect(screen.queryByRole('button', { name: 'Translate' })).toBeNull();
    expect(screen.queryByRole('button', { name: /Source language/ })).toBeNull();
    expect(document.querySelector('.status__translation-bar')).toBeNull();
  });

  it('shows the status language and the UI language before translation', () => {
    renderStatus(buildStatus());

    expect(screen.getByRole('button', { name: 'Source language, English' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Target language, 日本語' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Translate' })).toBeTruthy();
  });

  it('shows Unspecified for a missing status language and opens the source picker', () => {
    renderStatus(buildStatus({ language: null }));

    fireEvent.click(screen.getByRole('button', { name: 'Source language, Unspecified' }));

    expect(screen.getByRole('listbox')).toBeTruthy();
    expect(screen.getByRole('option', { name: /Unspecified/ })).toBeTruthy();
  });

  it('returns focus to the language button after closing the picker', async () => {
    renderStatus(buildStatus());
    const button = screen.getByRole('button', { name: 'Source language, English' });

    button.focus();
    fireEvent.click(button);

    const search = screen.getByPlaceholderText('Search languages...');

    await waitFor(() => {
      expect(document.activeElement).toBe(search);
    });

    fireEvent.keyDown(search, { key: 'Escape' });

    expect(document.activeElement).toBe(button);
    expect(screen.queryByRole('listbox')).toBeNull();
  });

  it('requests a supported viewer pair without changing status.language', () => {
    const onTranslate = jest.fn();
    const status = buildStatus();
    const store = createStore(interactiveReducer, fromJS({
      server: {
        translationLanguages: {
          items: { en: ['ja'], fr: ['ja'], und: ['ja'] },
        },
      },
      statuses: {},
      translation_assumptions: {},
    }).setIn(['statuses', 's1'], status));

    const { container } = render(
      <Provider store={store}>
        <StatusContent status={status} onTranslate={onTranslate} onClick={jest.fn()} />
      </Provider>,
    );

    fireEvent.click(screen.getByRole('button', { name: 'Source language, English' }));
    fireEvent.click(screen.getByRole('option', { name: /Français/ }));

    const translate = screen.getByRole('button', { name: 'Translate' });
    expect(translate).toBeEnabled();
    expect(screen.queryByText('This language pair is not supported.')).toBeNull();
    fireEvent.click(translate);

    expect(onTranslate).toHaveBeenCalledWith('translated');
    expect(status.get('language')).toBe('en');
    expect(store.getState().getIn(['statuses', 's1', 'language'])).toBe('en');
    expect(store.getState().getIn(['translation_assumptions', 's1'])).toBe('fr');
    expect(store.getState().getIn(['translation_assumptions', 's1', 'target'])).toBeUndefined();
    expect(container.querySelector('.status__content__text').textContent).toContain('Hello');
  });

  it('returns a loaded translation to the original text when the viewer pair changes', () => {
    const onTranslate = jest.fn();
    const status = buildStatus({
      translationMode: 'translated',
      translation: {
        contentHtml: '<p>こんにちは</p>',
        spoilerHtml: '',
        language: 'ja',
        detected_source_language: 'en',
        provider: 'DeepL',
      },
    });
    const store = createStore(interactiveReducer, fromJS({
      server: {
        translationLanguages: {
          items: { en: ['ja'], fr: ['ja'], und: ['ja'] },
        },
      },
      statuses: {},
      translation_assumptions: {},
    }).setIn(['statuses', 's1'], status));

    const { container, rerender } = render(
      <Provider store={store}>
        <StatusContent status={status} onTranslate={onTranslate} onClick={jest.fn()} />
      </Provider>,
    );

    expect(container.querySelector('.status__content__text').innerHTML).toContain('こんにちは');
    expect(screen.getByText('· DeepL')).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: 'Source language, English' }));
    fireEvent.click(screen.getByRole('option', { name: /Français/ }));

    expect(onTranslate).not.toHaveBeenCalled();
    expect(container.querySelector('.status__content__text').innerHTML).toContain('Hello');
    expect(screen.queryByText('· DeepL')).toBeNull();
    expect(store.getState().getIn(['statuses', 's1', 'language'])).toBe('en');
    expect(store.getState().getIn(['statuses', 's1', 'translationMode'])).toBe('original');
    expect(store.getState().getIn(['statuses', 's1', 'translation', 'provider'])).toBe('DeepL');
    expect(screen.getByRole('button', { name: 'Translate' })).toBeEnabled();

    fireEvent.click(screen.getByRole('button', { name: 'Source language, Français' }));
    fireEvent.click(screen.getByRole('option', { name: /English/ }));
    rerender(
      <Provider store={store}>
        <StatusContent status={store.getState().getIn(['statuses', 's1'])} onTranslate={onTranslate} onClick={jest.fn()} />
      </Provider>,
    );

    expect(screen.getByRole('button', { name: 'Original', pressed: true })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Translated', pressed: false })).toBeTruthy();
    expect(screen.getByText('· DeepL')).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Translate' })).toBeNull();
  });

  it('keeps the source selector on Unspecified when detection says English', () => {
    renderStatus(buildStatus({
      language: null,
      translationMode: 'translated',
      translation: {
        contentHtml: '<p>こんにちは</p>',
        spoilerHtml: '',
        language: 'ja',
        detected_source_language: 'en',
        provider: 'DeepL',
      },
    }));

    const source = screen.getByRole('button', { name: 'Source language, Unspecified' });
    expect(screen.queryByRole('button', { name: 'Source language, English' })).toBeNull();
    expect(screen.getByText('Detected English')).toBeTruthy();
    expect(screen.getByText('· DeepL')).toBeTruthy();

    fireEvent.click(source);

    expect(screen.getByRole('option', { name: /Unspecified/ })).toHaveAttribute('aria-selected', 'true');
    expect(screen.getByRole('option', { name: /English/ })).toHaveAttribute('aria-selected', 'false');
  });

  it('shows the declared language on the selector and the detected language as metadata', () => {
    renderStatus(buildStatus({
      language: 'ja',
      translationMode: 'translated',
      translation: {
        contentHtml: '<p>Hello</p>',
        spoilerHtml: '',
        language: 'en',
        detected_source_language: 'en',
        provider: 'LibreTranslate',
      },
    }));

    expect(screen.getByRole('button', { name: 'Source language, 日本語' })).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Source language, English' })).toBeNull();
    expect(screen.getByRole('button', { name: 'Target language, 日本語' })).toBeTruthy();
    expect(screen.getByText('Detected English')).toBeTruthy();
    expect(screen.getByText('· LibreTranslate')).toBeTruthy();
  });

  it('lets the viewer correct a declared language and request that pair', () => {
    const onTranslate = jest.fn();
    const status = buildStatus({ language: 'ja', contentHtml: '<p>Hello</p>', search_index: 'Hello' });
    const store = createStore(interactiveReducer, fromJS({
      server: {
        translationLanguages: {
          items: { en: ['ja'], fr: ['ja'], und: ['ja'] },
        },
      },
      statuses: {},
      translation_assumptions: {},
    }).setIn(['statuses', 's1'], status));

    render(
      <Provider store={store}>
        <StatusContent status={status} onTranslate={onTranslate} onClick={jest.fn()} />
      </Provider>,
    );

    const translate = screen.getByRole('button', { name: 'Translate' });
    expect(translate).toBeDisabled();
    expect(screen.getByRole('button', { name: 'Bilingual' })).toBeDisabled();
    expect(screen.queryByText('This language pair is not supported.')).toBeNull();
    expect(translate).not.toHaveAttribute('title');
    expect(translate).not.toHaveAttribute('aria-describedby');

    fireEvent.click(screen.getByRole('button', { name: 'Source language, 日本語' }));
    fireEvent.click(screen.getByRole('option', { name: /English/ }));

    expect(screen.getByRole('button', { name: 'Translate' })).toBeEnabled();
    expect(screen.getByRole('button', { name: 'Bilingual' })).toBeEnabled();
    expect(screen.queryByText('This language pair is not supported.')).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: 'Translate' }));

    expect(onTranslate).toHaveBeenCalledWith('translated');
    expect(status.get('language')).toBe('ja');
    expect(store.getState().getIn(['statuses', 's1', 'language'])).toBe('ja');
    expect(store.getState().getIn(['translation_assumptions', 's1'])).toBe('en');
    expect(store.getState().getIn(['translation_assumptions', 's1', 'target'])).toBeUndefined();
  });

  it('builds source and target choices from provider languages, including provider-only codes', () => {
    const status = buildStatus({ language: 'ja' });
    const store = createStore(interactiveReducer, fromJS({
      server: {
        translationLanguages: {
          items: {
            en: ['ja', 'de'],
            'zh-Hans': ['ja'],
            'zh-Hant': ['en'],
            und: ['ja'],
          },
        },
      },
      statuses: {},
      translation_assumptions: {},
    }).setIn(['statuses', 's1'], status));

    render(
      <Provider store={store}>
        <StatusContent status={status} onTranslate={jest.fn()} onClick={jest.fn()} />
      </Provider>,
    );

    fireEvent.click(screen.getByRole('button', { name: 'Source language, 日本語' }));

    expect(screen.getByRole('option', { name: /Unspecified/ })).toBeTruthy();
    expect(screen.getByRole('option', { name: /English/ })).toBeTruthy();
    expect(screen.getByRole('option', { name: '简体中文 (簡体中国語)' })).toBeTruthy();
    expect(screen.getByRole('option', { name: '繁體中文 (繁体中国語)' })).toBeTruthy();
    expect(screen.getByRole('option', { name: /日本語/ })).toHaveAttribute('aria-selected', 'true');
    expect(screen.queryByRole('option', { name: /Français/ })).toBeNull();

    fireEvent.click(screen.getByRole('option', { name: /English/ }));
    fireEvent.click(screen.getByRole('button', { name: 'Target language, 日本語' }));

    expect(screen.getByRole('option', { name: /日本語/ })).toHaveAttribute('aria-selected', 'true');
    expect(screen.getByRole('option', { name: 'de (ドイツ語)' })).toBeTruthy();
    expect(screen.queryByRole('option', { name: /English/ })).toBeNull();
  });

  it('keeps the current target visible when the selected source does not support it', () => {
    const onTranslate = jest.fn();
    const status = buildStatus();
    const store = createStore(interactiveReducer, fromJS({
      server: {
        translationLanguages: {
          items: { en: ['ja'], fr: ['de'], und: ['ja'] },
        },
      },
      statuses: {},
      translation_assumptions: {},
    }).setIn(['statuses', 's1'], status));

    render(
      <Provider store={store}>
        <StatusContent status={status} onTranslate={onTranslate} onClick={jest.fn()} />
      </Provider>,
    );

    fireEvent.click(screen.getByRole('button', { name: 'Source language, English' }));
    fireEvent.click(screen.getByRole('option', { name: /Français/ }));

    expect(screen.getByRole('button', { name: 'Target language, 日本語' })).toBeTruthy();
    expect(store.getState().getIn(['translation_assumptions', 's1'])).toBe('fr');
    expect(store.getState().getIn(['translation_assumptions', 's1', 'target'])).toBeUndefined();
    expectUnsupportedPair();

    fireEvent.click(screen.getByRole('button', { name: 'Target language, 日本語' }));
    expect(screen.getByRole('option', { name: /日本語/ })).toHaveAttribute('aria-selected', 'true');
    expect(screen.getByRole('option', { name: 'de (ドイツ語)' })).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Translate' }));

    expect(onTranslate).not.toHaveBeenCalled();
  });

  it('reuses a translation only when its stored request pair matches the viewer pair', () => {
    const matching = buildStatus({
      translationMode: 'translated',
      translation: {
        contentHtml: '<p>こんにちは</p>',
        spoilerHtml: '',
        language: 'ja',
        detected_source_language: 'fr',
        requested_source_language: 'en',
        requested_target_language: 'ja',
        provider: 'DeepL',
      },
    });
    const { unmount, container } = renderStatus(matching);

    expect(container.querySelector('.status__content__text').innerHTML).toContain('こんにちは');
    expect(screen.getByText('Detected Français')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Source language, English' })).toBeTruthy();
    unmount();

    const different = buildStatus({
      translationMode: 'translated',
      translation: {
        contentHtml: '<p>Bonjour</p>',
        spoilerHtml: '',
        language: 'fr',
        detected_source_language: 'en',
        requested_source_language: 'en',
        requested_target_language: 'fr',
        provider: 'DeepL',
      },
    });
    const second = renderStatus(different);

    expect(second.container.querySelector('.status__content__text').innerHTML).toContain('Hello');
    expect(screen.queryByText('· DeepL')).toBeNull();
    expect(screen.getByRole('button', { name: 'Translate' })).toBeEnabled();
  });

  it('wraps the translation bar instead of overlapping status content', () => {
    const css = readFileSync(resolve('app/javascript/styles/mastodon/components.scss'), 'utf8');
    const block = css.match(/\.status__translation-bar \{[^}]+\}/)[0];

    expect(block).toContain('display: flex');
    expect(block).toContain('flex-wrap: wrap');
    expect(block).not.toContain('position: absolute');
    expect(block).not.toContain('position: fixed');
  });
});
