/* eslint-disable react/prop-types */

import { fireEvent, render, screen } from '@testing-library/react';
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

import LanguageDropdown from '../language_dropdown';

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
  it('shows the current language code and selects a searched language', () => {
    const { onChange, onClose } = renderDropdown();
    const button = screen.getByRole('button', { name: 'Change language' });

    expect(button).toHaveTextContent('JA');

    fireEvent.click(button);

    expect(screen.getByRole('listbox')).toBeInTheDocument();
    expect(screen.getAllByRole('option')[0]).toHaveAttribute('aria-selected', 'true');

    fireEvent.change(screen.getByPlaceholderText('Search languages...'), { target: { value: 'eng' } });

    const english = screen.getByRole('option', { name: /English/ });
    expect(screen.getAllByRole('option')).toHaveLength(1);

    fireEvent.click(english);

    expect(onChange).toHaveBeenCalledWith('en');
    expect(onClose).toHaveBeenCalled();
    expect(screen.queryByRole('listbox')).not.toBeInTheDocument();
  });

  it('closes from the search field with Escape', () => {
    renderDropdown();

    fireEvent.click(screen.getByRole('button', { name: 'Change language' }));
    fireEvent.keyDown(screen.getByPlaceholderText('Search languages...'), { key: 'Escape' });

    expect(screen.queryByRole('listbox')).not.toBeInTheDocument();
  });
});
