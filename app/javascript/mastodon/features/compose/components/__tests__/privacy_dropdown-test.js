import { fireEvent, render, screen } from '@testing-library/react';
import { Set as ImmutableSet } from 'immutable';
import React from 'react';

jest.mock('react-intl', () => {
  const intl = {
    formatMessage: ({ defaultMessage }) => defaultMessage,
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
  };
});

jest.mock('react-overlays/Overlay', () => {
  return ({ show, children }) => (show ? children({ props: { style: {} }, placement: 'bottom' }) : null);
});

jest.mock('mastodon/initial_state', () => ({
  hidePrivacyMeta: false,
}));

import PrivacyDropdown from '../privacy_dropdown';

const renderDropdown = (props = {}) => {
  const onChange = jest.fn();

  render(
    <PrivacyDropdown
      value='public'
      onChange={onChange}
      {...props}
    />,
  );

  return { onChange };
};

const optionValues = () => screen.getAllByRole('option').map(option => option.getAttribute('data-index'));

describe('PrivacyDropdown', () => {
  it('shows the current visibility icon and label', () => {
    renderDropdown();
    const button = screen.getByRole('button', { name: 'Adjust status privacy' });

    expect(button).toHaveTextContent('Public');
    expect(button.querySelector('.fa-globe')).not.toBeNull();
    expect(button).toHaveAttribute('type', 'button');
    expect(button).toHaveAttribute('aria-expanded', 'false');
    expect(button).not.toBeDisabled();
  });

  it('opens the existing visibility list and reports the selected option', () => {
    const { onChange } = renderDropdown({ value: 'private' });
    const button = screen.getByRole('button', { name: 'Adjust status privacy' });

    expect(button).toHaveTextContent('Followers-only');

    fireEvent.click(button);

    expect(button).toHaveAttribute('aria-expanded', 'true');
    expect(optionValues()).toEqual(['public', 'unlisted', 'private', 'mutual', 'limited', 'direct', 'personal']);

    fireEvent.click(screen.getByRole('option', { name: /Mutuals-followers-only/ }));

    expect(onChange).toHaveBeenCalledWith('mutual');
    expect(screen.queryByRole('listbox')).not.toBeInTheDocument();
  });

  it('does not change visibility when disabled', () => {
    const { onChange } = renderDropdown({ disabled: true });
    const button = screen.getByRole('button', { name: 'Adjust status privacy' });

    expect(button).toBeDisabled();

    fireEvent.click(button);

    expect(onChange).not.toHaveBeenCalled();
    expect(screen.queryByRole('listbox')).not.toBeInTheDocument();
    expect(button).toHaveAttribute('aria-expanded', 'false');
  });

  it('hides prohibited visibilities and keeps the remaining Fedibird options', () => {
    renderDropdown({ prohibitedVisibilities: ImmutableSet(['direct', 'personal']) });

    fireEvent.click(screen.getByRole('button', { name: 'Adjust status privacy' }));

    expect(optionValues()).toEqual(['public', 'unlisted', 'private', 'mutual', 'limited']);
  });
});
