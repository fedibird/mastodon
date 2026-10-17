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
  it('offers only search ranges allowed by the current post visibility', () => {
    const props = { presentation: 'detached', open: true, value: 'private', privacy: 'private', onChange: jest.fn(), onClose: jest.fn() };
    const view = render(<SearchabilityDropdown {...props} />);

    expect(screen.queryByRole('option', { name: /Public/ })).toBeNull();
    expect(screen.getByRole('option', { name: /Followers-only/ })).toHaveAttribute('aria-selected', 'true');
    view.rerender(<SearchabilityDropdown {...props} value='direct' privacy='mutual' />);
    expect(screen.queryByRole('option', { name: /Followers-only/ })).toBeNull();
    expect(screen.getByRole('option', { name: /Reacted-users-only/ })).toHaveAttribute('aria-selected', 'true');
    view.rerender(<SearchabilityDropdown {...props} privacy='public' />);
    expect(screen.getByRole('option', { name: /Public/ })).toBeTruthy();
  });

  it('selects a visibility and closes the dedicated menu', () => {
    const { onChange, onClose } = renderMenu();

    expect(screen.getByRole('listbox')).toHaveClass('compose-form__searchability-menu');
    expect(screen.queryByText('🔎')).toBeNull();

    expect(screen.getByRole('option', { name: /Followers-only/ })).toHaveAttribute('aria-selected', 'true');
    expect(screen.getByRole('option', { name: /Followers-only/ })).toHaveClass('active');
    expect(screen.getByRole('option', { name: /Public/ })).toHaveAttribute('aria-selected', 'false');

    fireEvent.click(screen.getByRole('option', { name: /Public/ }));

    expect(onChange).toHaveBeenCalledWith('public');
    expect(onClose).toHaveBeenCalled();
  });

  it('moves focus with the arrow keys without saving a new value', () => {
    const { onChange } = renderMenu({ value: 'private' });
    const current = screen.getByRole('option', { name: /Followers-only/ });

    fireEvent.keyDown(current, { key: 'ArrowDown' });

    expect(onChange).not.toHaveBeenCalled();
    expect(current).toHaveAttribute('aria-selected', 'true');
    expect(document.activeElement).toBe(screen.getByRole('option', { name: /Reacted-users-only/ }));
  });

  it('rebuilds the choices when a visibility becomes prohibited', () => {
    const props = {
      presentation: 'detached',
      open: true,
      value: 'private',
      onChange: jest.fn(),
      onClose: jest.fn(),
    };
    const view = render(<SearchabilityDropdown {...props} />);

    expect(screen.getByRole('option', { name: /Public/ })).toHaveAttribute('aria-selected', 'false');
    expect(screen.getByRole('option', { name: /Followers-only/ })).toHaveAttribute('aria-selected', 'true');

    view.rerender(<SearchabilityDropdown {...props} prohibitedVisibilities={ImmutableSet(['public'])} />);

    expect(screen.queryByRole('option', { name: /Public/ })).toBeNull();
    expect(screen.getByRole('option', { name: /Followers-only/ })).toHaveClass('active');
    expect(screen.getByRole('option', { name: /Followers-only/ })).toHaveAttribute('aria-selected', 'true');
    expect(screen.getAllByRole('option').filter(option => option.getAttribute('aria-selected') === 'true')).toHaveLength(1);
  });

  it('does not highlight a value that is not in the menu', () => {
    renderMenu({ value: 'public', prohibitedVisibilities: ImmutableSet(['public']) });

    expect(screen.queryByRole('option', { name: /Public/ })).toBeNull();
    screen.getAllByRole('option').forEach(option => {
      expect(option).toHaveAttribute('aria-selected', 'false');
      expect(option).not.toHaveClass('active');
    });
  });

  const openTouchSheet = (extra = {}) => {
    const onChange = jest.fn();
    const onModalOpen = jest.fn();
    const onModalClose = jest.fn();
    const props = {
      presentation: 'detached',
      value: 'private',
      isUserTouching: () => true,
      onModalOpen,
      onModalClose,
      onChange,
      onClose: jest.fn(),
      ...extra,
    };
    const view = render(<SearchabilityDropdown {...props} open={false} />);

    view.rerender(<SearchabilityDropdown {...props} open />);

    return { view, props, onChange, onModalOpen, onModalClose };
  };

  const clickOpenedIndex = (onClick, index) => {
    const anchor = document.createElement('a');

    anchor.setAttribute('data-index', String(index));
    onClick({
      preventDefault () {},
      currentTarget: anchor,
    });
  };

  it('does not confirm a shifted touch option after the menu choices change', () => {
    const { view, props, onChange, onModalOpen } = openTouchSheet();
    const opened = onModalOpen.mock.calls[0][0];

    expect(opened.actions.map(action => action.value)).toEqual(['public', 'private', 'direct']);

    view.rerender(
      <SearchabilityDropdown
        {...props}
        open
        prohibitedVisibilities={ImmutableSet(['public'])}
      />,
    );

    clickOpenedIndex(opened.onClick, 1);

    expect(onChange).toHaveBeenCalledTimes(1);
    expect(onChange).toHaveBeenCalledWith('private');
  });

  it('does not apply a touch option that became prohibited after the menu opened', () => {
    const { view, props, onChange, onModalOpen, onModalClose } = openTouchSheet();
    const opened = onModalOpen.mock.calls[0][0];

    view.rerender(
      <SearchabilityDropdown
        {...props}
        open
        prohibitedVisibilities={ImmutableSet(['public'])}
      />,
    );

    clickOpenedIndex(opened.onClick, 0);

    expect(onModalClose).toHaveBeenCalledTimes(1);
    expect(onChange).not.toHaveBeenCalled();
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
    expect(onModalOpen.mock.calls[0][0].actions.find(action => action.value === 'private').active).toBe(true);
    expect(onModalOpen.mock.calls[0][0].actions.filter(action => action.active)).toHaveLength(1);
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
