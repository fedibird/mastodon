/* eslint-disable react/prop-types */

import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import React from 'react';

jest.mock('react-intl', () => {
  const intl = {
    formatMessage: ({ defaultMessage }) => defaultMessage,
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
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
    const button = screen.getByRole('button', { name: 'Change language' });

    expect(button).toHaveTextContent('日本語');
    expect(button.querySelector('.fa-language')).not.toBeNull();
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

    expect(screen.getByRole('button', { name: 'Change language' })).toHaveTextContent('de');
  });

  it('returns focus to the language button after Escape', async () => {
    renderDropdown();
    const button = screen.getByRole('button', { name: 'Change language' });

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

    fireEvent.click(screen.getByRole('button', { name: 'Change language' }));
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

    fireEvent.click(screen.getByRole('button', { name: 'Change language' }));

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
