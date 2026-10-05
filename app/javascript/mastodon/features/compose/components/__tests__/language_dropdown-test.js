/* eslint-disable react/prop-types */

import fs from 'fs';
import path from 'path';

import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import React from 'react';

const jaMessages = JSON.parse(fs.readFileSync(path.join(__dirname, '../../../../locales/ja.json'), 'utf8'));

jest.mock('react-intl', () => {
  const intl = {
    formatMessage: ({ defaultMessage }) => defaultMessage,
  };

  return {
    injectIntl: Component => props => {
      const { intl: intlOverride, ...rest } = props;

      return <Component {...rest} intl={intlOverride || intl} />;
    },
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

jest.mock('react-overlays/Overlay', () => {
  return ({ show, children }) => (show ? children({ props: { style: {} }, placement: 'bottom' }) : null);
});

import { fromJS } from 'immutable';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

import LanguageDropdownMenu from 'mastodon/components/language_dropdown_menu';

import LanguageDropdown from '../language_dropdown';
import LanguageDropdownContainer from '../../containers/language_dropdown_container';

const languages = [
  ['en', 'English', 'English'],
  ['ja', 'Japanese', '日本語'],
  ['fr', 'French', 'Français'],
];

const renderDropdown = (props = {}) => {
  const onChange = jest.fn();
  const onClose = jest.fn();

  render(
    <LanguageDropdown
      value='ja'
      frequentlyUsedLanguages={['fr']}
      languages={languages}
      onChange={onChange}
      onClose={onClose}
      {...props}
    />,
  );

  return { onChange, onClose };
};

describe('LanguageDropdown', () => {
  it('shows the current language name and selects a searched language', () => {
    const { onChange, onClose } = renderDropdown();
    const button = screen.getByRole('button', { name: '日本語' });

    expect(button).toHaveTextContent('日本語');
    expect(button.querySelector('.fa-language')).not.toBeNull();
    expect(button).toHaveAttribute('title', 'Change language');
    expect(button).not.toHaveAttribute('aria-label');
    expect(button).toHaveAttribute('aria-expanded', 'false');

    fireEvent.click(button);

    expect(button).toHaveAttribute('aria-expanded', 'true');
    expect(screen.getByRole('listbox')).toBeInTheDocument();
    expect(screen.getAllByRole('option').map(option => option.getAttribute('data-index'))).toEqual(['ja', 'fr', 'en']);
    expect(screen.getAllByRole('option')[0]).toHaveAttribute('aria-selected', 'true');

    fireEvent.change(screen.getByPlaceholderText('Search languages...'), { target: { value: 'eng' } });

    const english = screen.getByRole('option', { name: /English/ });
    expect(screen.getAllByRole('option')).toHaveLength(1);

    fireEvent.click(english);

    expect(onChange).toHaveBeenCalledWith('en');
    expect(onClose).toHaveBeenCalledWith('en');
    expect(onChange.mock.invocationCallOrder[0]).toBeLessThan(onClose.mock.invocationCallOrder[0]);
    expect(screen.queryByRole('listbox')).not.toBeInTheDocument();
  });

  it('falls back to the language code when the native name is unknown', () => {
    renderDropdown({ value: 'de' });

    expect(screen.getByRole('button', { name: 'de' })).toHaveTextContent('de');
  });

  it('returns focus to the language button after Escape', async () => {
    renderDropdown();
    const button = screen.getByRole('button', { name: '日本語' });

    button.focus();
    fireEvent.click(button);

    const search = screen.getByPlaceholderText('Search languages...');

    await waitFor(() => {
      expect(document.activeElement).toBe(search);
    });

    fireEvent.keyDown(search, { key: 'Escape' });

    expect(document.activeElement).toBe(button);
    expect(screen.queryByRole('listbox')).not.toBeInTheDocument();
  });

  it('closes from the search field with Escape', () => {
    renderDropdown();

    fireEvent.click(screen.getByRole('button', { name: '日本語' }));
    fireEvent.keyDown(screen.getByPlaceholderText('Search languages...'), { key: 'Escape' });

    expect(screen.queryByRole('listbox')).not.toBeInTheDocument();
  });

  it('keeps compose order when translation target counts would rank another language first', () => {
    const composeLanguages = [
      ['en', 'English', 'English'],
      ['ja', 'Japanese', '日本語'],
      ['fr', 'French', 'Français'],
      ['de', 'German', 'Deutsch'],
    ];
    const store = createStore(() => fromJS({
      compose: { language: 'ja' },
      settings: {
        frequentlyUsedLanguages: { fr: 2, en: 1 },
        translation: { targetLanguageUsage: { de: 9, en: 8 } },
      },
    }));

    render(
      <Provider store={store}>
        <LanguageDropdownContainer languages={composeLanguages} />
      </Provider>,
    );

    fireEvent.click(screen.getByRole('button', { name: '日本語' }));

    expect(screen.getAllByRole('option').map(option => option.getAttribute('data-index'))).toEqual(['ja', 'fr', 'en', 'de']);
  });
});

describe('LanguageDropdownMenu ordering', () => {
  const menuLanguages = [
    ['en', 'English', 'English'],
    ['ja', 'Japanese', '日本語'],
    ['fr', 'French', 'Français'],
    ['de', 'German', 'Deutsch'],
  ];

  const renderMenu = (props = {}) => render(
    <LanguageDropdownMenu
      value='de'
      languages={menuLanguages}
      frequentlyUsedLanguages={['fr', 'en']}
      onClose={jest.fn()}
      onChange={jest.fn()}
      intl={{ formatMessage: ({ defaultMessage }) => defaultMessage }}
      {...props}
    />,
  );

  const codes = () => screen.getAllByRole('option').map(option => option.getAttribute('data-index'));

  it('puts the current language before frequently used languages by default', () => {
    renderMenu();

    expect(codes()).toEqual(['de', 'fr', 'en', 'ja']);
  });

  it('pins languages without moving the current value when asked', () => {
    renderMenu({ pinnedLanguages: ['ja'], currentValueFirst: false });

    expect(codes()).toEqual(['ja', 'fr', 'en', 'de']);
  });

  it('keeps search relevance ahead of a pinned language', () => {
    renderMenu({ pinnedLanguages: ['ja'], currentValueFirst: false });
    fireEvent.change(screen.getByPlaceholderText('Search languages...'), { target: { value: 'eng' } });

    expect(codes()).toEqual(['en']);
  });
});

describe('localized composer language names', () => {
  const jaIntl = {
    locale: 'ja',
    formatMessage: ({ id, defaultMessage }) => jaMessages[id] || defaultMessage,
  };

  const localizedLanguages = [
    ['en', 'English', 'English'],
    ['ja', 'Japanese', '日本語'],
    ['de', 'German', 'Deutsch'],
    ['fr', 'French', 'Français'],
    ['zh', 'Chinese', '中文'],
    ['zh-CN', 'Chinese (China)', '简体中文'],
    ['zh-TW', 'Chinese (Taiwan)', '繁體中文（臺灣）'],
    ['zh-HK', 'Chinese (Hong Kong)', '繁體中文（香港）'],
    ['zh-YUE', 'Cantonese', '廣東話'],
    ['ldn', 'Láadan', 'Láadan'],
    ['zba', 'Balaibalan', 'باليبلن'],
    ['zz', 'Mystery', '???'],
    ['not-a-language', 'Nope', 'Nopeish'],
  ];

  const renderLocalizedMenu = (props = {}) => render(
    <LanguageDropdownMenu
      value='ja'
      languages={localizedLanguages}
      frequentlyUsedLanguages={[]}
      onClose={jest.fn()}
      onChange={jest.fn()}
      intl={jaIntl}
      {...props}
    />,
  );

  const optionNames = () => screen.getAllByRole('option').map(option => option.textContent.replace(/\s+/g, ' ').trim());

  it('resolves the composer language messages in the Japanese locale', () => {
    renderDropdown({ intl: jaIntl, languages: localizedLanguages });

    const button = screen.getByRole('button', { name: '日本語' });

    expect(button).toHaveTextContent('日本語');
    expect(button).not.toHaveTextContent('英語');
    expect(button).toHaveAttribute('title', '言語を変更');

    fireEvent.click(button);

    expect(screen.getByPlaceholderText('言語を検索...')).toBeInTheDocument();
  });

  it('keeps the composer button on the native name', () => {
    renderDropdown({ intl: jaIntl, value: 'de', languages: localizedLanguages });

    const button = screen.getByRole('button', { name: 'Deutsch' });

    expect(button).toHaveTextContent('Deutsch');
    expect(button).not.toHaveTextContent('ドイツ語');
    expect(button).toHaveAttribute('title', '言語を変更');
  });

  it('shows Japanese common names and omits a redundant parenthetical', () => {
    renderLocalizedMenu();

    expect(optionNames()).toEqual(expect.arrayContaining([
      '日本語',
      'English (英語)',
      'Deutsch (ドイツ語)',
      'Français (フランス語)',
      '中文 (中国語)',
      '简体中文 (中国語・中国)',
      '繁體中文（臺灣） (中国語・台湾)',
      '繁體中文（香港） (中国語・香港)',
      '廣東話 (広東語)',
      'Láadan (ラーダン語)',
      'باليبلن (バライバラン語)',
    ]));
    expect(screen.getByRole('option', { name: '日本語' }).querySelector('.language-dropdown__dropdown__results__item__common-name')).toBeNull();
  });

  it('searches localized Japanese names, English common names, and native names', () => {
    renderLocalizedMenu();
    const search = screen.getByPlaceholderText('言語を検索...');

    fireEvent.change(search, { target: { value: 'ドイツ' } });
    expect(screen.getAllByRole('option').map(option => option.getAttribute('data-index'))).toEqual(['de']);
    expect(screen.getByRole('option', { name: 'Deutsch (ドイツ語)' })).toBeInTheDocument();

    fireEvent.change(search, { target: { value: 'German' } });
    expect(screen.getAllByRole('option').map(option => option.getAttribute('data-index'))).toEqual(['de']);

    fireEvent.change(search, { target: { value: 'Deutsch' } });
    expect(screen.getAllByRole('option').map(option => option.getAttribute('data-index'))).toEqual(['de']);

    fireEvent.change(search, { target: { value: 'フランス' } });
    expect(screen.getAllByRole('option').map(option => option.getAttribute('data-index'))).toEqual(['fr']);

    fireEvent.change(search, { target: { value: '中国' } });
    expect(screen.getAllByRole('option').map(option => option.getAttribute('data-index'))).toEqual(expect.arrayContaining(['zh', 'zh-CN', 'zh-TW', 'zh-HK']));
    expect(screen.getByRole('option', { name: '中文 (中国語)' })).toBeInTheDocument();
    expect(screen.getByRole('option', { name: '简体中文 (中国語・中国)' })).toBeInTheDocument();

    fireEvent.change(search, { target: { value: '香港' } });
    expect(screen.getAllByRole('option').map(option => option.getAttribute('data-index'))).toEqual(['zh-HK']);
    expect(screen.getByRole('option', { name: '繁體中文（香港） (中国語・香港)' })).toBeInTheDocument();

    fireEvent.change(search, { target: { value: 'eng' } });
    expect(screen.getAllByRole('option').map(option => option.getAttribute('data-index'))).toEqual(['en']);

    fireEvent.change(search, { target: { value: 'de' } });
    expect(screen.getAllByRole('option').map(option => option.getAttribute('data-index'))).toContain('de');
  });

  it('falls back to the English common name when Intl.DisplayNames is unavailable', () => {
    const original = Intl.DisplayNames;
    Intl.DisplayNames = undefined;

    try {
      renderLocalizedMenu({
        languages: [
          ['ja', 'Japanese', '日本語'],
          ['de', 'German', 'Deutsch'],
          ['en', 'English', 'English'],
          ['zh-CN', 'Chinese (China)', '简体中文'],
          ['zh-HK', 'Chinese (Hong Kong)', '繁體中文（香港）'],
          ['zh-YUE', 'Cantonese', '廣東話'],
        ],
      });

      expect(screen.getByRole('option', { name: '日本語 (Japanese)' })).toBeInTheDocument();
      expect(screen.getByRole('option', { name: 'Deutsch (German)' })).toBeInTheDocument();
      expect(screen.getByRole('option', { name: 'English' })).toBeInTheDocument();
      expect(screen.getByRole('option', { name: '简体中文 (Chinese (China))' })).toBeInTheDocument();
      expect(screen.getByRole('option', { name: '繁體中文（香港） (Chinese (Hong Kong))' })).toBeInTheDocument();
      expect(screen.getByRole('option', { name: '廣東話 (Cantonese)' })).toBeInTheDocument();
      expect(screen.queryByText('ドイツ語')).not.toBeInTheDocument();
      expect(screen.queryByText('中国語・香港')).not.toBeInTheDocument();
      expect(screen.queryByText('広東語')).not.toBeInTheDocument();
    } finally {
      Intl.DisplayNames = original;
    }
  });

  it('does not crash for an unknown language code', () => {
    renderLocalizedMenu({
      languages: [
        ['zz', 'Mystery', '???'],
        ['not-a-language', 'Nope', 'Nopeish'],
      ],
      value: 'zz',
    });

    expect(screen.getByRole('option', { name: '??? (Mystery)' })).toBeInTheDocument();
    expect(screen.getByRole('option', { name: 'Nopeish (Nope)' })).toBeInTheDocument();
  });
});
