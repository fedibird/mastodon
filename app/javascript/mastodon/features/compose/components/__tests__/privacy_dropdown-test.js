import { fireEvent, render, screen } from '@testing-library/react';
import { fromJS, Set as ImmutableSet } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

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

import PrivacyDropdownContainer from '../../containers/privacy_dropdown_container';
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
  it('shows the current visibility icon and label when showLabel is set', () => {
    renderDropdown({ showLabel: true });
    const button = screen.getByRole('button', { name: 'Public' });

    expect(button).toHaveTextContent('Public');
    expect(button.querySelector('.fa-globe')).not.toBeNull();
    expect(button.querySelector('.dropdown-button__label')).toHaveTextContent('Public');
    expect(button).toHaveAttribute('type', 'button');
    expect(button).toHaveAttribute('title', 'Adjust status privacy');
    expect(button).not.toHaveAttribute('aria-label');
    expect(button).toHaveAttribute('aria-expanded', 'false');
    expect(button).not.toBeDisabled();
  });

  it('opens the existing visibility list and reports the selected option', () => {
    const { onChange } = renderDropdown({ showLabel: true, value: 'private' });
    const button = screen.getByRole('button', { name: 'Followers-only' });

    expect(button).toHaveAttribute('aria-expanded', 'false');

    fireEvent.click(button);

    expect(button).toHaveAttribute('aria-expanded', 'true');
    expect(optionValues()).toEqual(['public', 'unlisted', 'private', 'mutual', 'limited', 'direct', 'personal']);

    fireEvent.click(screen.getByRole('option', { name: /Mutuals-followers-only/ }));

    expect(onChange).toHaveBeenCalledWith('mutual');
    expect(screen.queryByRole('listbox')).not.toBeInTheDocument();
  });

  it('does not change visibility when disabled', () => {
    const { onChange } = renderDropdown({ showLabel: true, disabled: true });
    const button = screen.getByRole('button', { name: 'Public' });

    expect(button).toBeDisabled();

    fireEvent.click(button);

    expect(onChange).not.toHaveBeenCalled();
    expect(screen.queryByRole('listbox')).not.toBeInTheDocument();
    expect(button).toHaveAttribute('aria-expanded', 'false');
  });

  it('hides prohibited visibilities and keeps the remaining Fedibird options', () => {
    renderDropdown({ showLabel: true, prohibitedVisibilities: ImmutableSet(['direct', 'personal']) });

    fireEvent.click(screen.getByRole('button', { name: 'Public' }));

    expect(optionValues()).toEqual(['public', 'unlisted', 'private', 'mutual', 'limited']);
  });

  it('keeps the icon-only button when showLabel is omitted', () => {
    renderDropdown();
    const button = screen.getByRole('button', { name: 'Adjust status privacy' });

    expect(button).toHaveClass('icon-button');
    expect(button).toHaveClass('privacy-dropdown__value-icon');
    expect(button.querySelector('.fa-globe')).not.toBeNull();
    expect(button.querySelector('.dropdown-button__label')).toBeNull();
    expect(document.querySelector('.dropdown-button__label')).toBeNull();
    expect(screen.queryByRole('button', { name: 'Public' })).not.toBeInTheDocument();
  });

  it('forwards showLabel through the connected container', () => {
    const store = createStore(() => fromJS({
      compose: {
        privacy: 'private',
        prohibited_visibilities: null,
      },
    }));

    render(
      <Provider store={store}>
        <PrivacyDropdownContainer showLabel />
      </Provider>,
    );

    expect(screen.getByRole('button', { name: 'Followers-only' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Followers-only' }).querySelector('.dropdown-button__label')).toHaveTextContent('Followers-only');
  });
});
