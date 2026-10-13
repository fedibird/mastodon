import { fireEvent, render, screen } from '@testing-library/react';
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
  return ({ show, children }) => (show ? children({ props: { style: {}, ref: jest.fn() }, placement: 'bottom' }) : null);
});

import SearchabilityDropdown from '../searchability_dropdown';

const renderMenu = (props = {}) => {
  const onChange = jest.fn();
  const onClose = jest.fn();
  const trigger = document.createElement('button');

  trigger.type = 'button';
  document.body.appendChild(trigger);

  render(
    <SearchabilityDropdown
      presentation='detached'
      open
      value='private'
      onChange={onChange}
      onClose={onClose}
      returnFocus={trigger}
      {...props}
    />,
  );

  return { onChange, onClose, trigger };
};

describe('SearchabilityDropdown detached menu', () => {
  it('selects a visibility and closes the dedicated menu', () => {
    const { onChange, onClose } = renderMenu();

    expect(screen.getByRole('listbox')).toHaveClass('compose-form__searchability-menu');
    expect(screen.queryByText('🔎')).toBeNull();

    fireEvent.click(screen.getByRole('option', { name: /Public/ }));

    expect(onChange).toHaveBeenCalledWith('public');
    expect(onClose).toHaveBeenCalled();
  });

  it('uses the touch action sheet instead of the desktop menu', () => {
    const onModalOpen = jest.fn();
    const onClose = jest.fn();
    const props = {
      presentation: 'detached',
      value: 'private',
      isUserTouching: () => true,
      onModalOpen,
      onModalClose: jest.fn(),
      onChange: jest.fn(),
      onClose,
    };
    const view = render(<SearchabilityDropdown {...props} open={false} />);

    view.rerender(<SearchabilityDropdown {...props} open />);

    expect(onModalOpen).toHaveBeenCalledTimes(1);
    expect(onModalOpen.mock.calls[0][0].actions.map(action => action.value)).toEqual(['public', 'private', 'direct']);
    expect(onClose).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole('listbox')).toBeNull();
  });

  it('returns focus to the overflow trigger on Escape and closes on an outside click', () => {
    const { onClose, trigger } = renderMenu();
    const option = screen.getByRole('option', { name: /Followers-only/ });

    option.focus();
    fireEvent.keyDown(option, { key: 'Escape' });

    expect(onClose).toHaveBeenCalledTimes(1);
    expect(document.activeElement).toBe(trigger);

    onClose.mockClear();
    fireEvent.click(document.body);

    expect(onClose).toHaveBeenCalledTimes(1);
  });
});
