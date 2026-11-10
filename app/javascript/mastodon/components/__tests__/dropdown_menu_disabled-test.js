/**
 * @jest-environment jsdom
 */

import React from 'react';
import { fireEvent, render, screen } from '@testing-library/react';
import { DropdownMenu } from '../dropdown_menu';

describe('DropdownMenu disabled items', () => {
  it('exposes aria-disabled and skips activation for disabled options', () => {
    const onItemClick = jest.fn();
    const onClose = jest.fn();
    const action = jest.fn();

    render(
      <DropdownMenu
        items={[
          { text: 'Disabled action', disabled: true, action },
          { text: 'Enabled action', disabled: false },
        ]}
        onClose={onClose}
        onItemClick={onItemClick}
      />,
    );

    const disabled = screen.getByRole('button', { name: 'Disabled action' });
    const enabled = screen.getByRole('button', { name: 'Enabled action' });

    expect(disabled).toHaveAttribute('aria-disabled', 'true');
    expect(disabled).toHaveAttribute('tabindex', '-1');
    expect(disabled.closest('li')).toHaveClass('dropdown-menu__item--disabled');
    expect(enabled).not.toHaveAttribute('aria-disabled');
    expect(enabled).toHaveAttribute('tabindex', '0');

    fireEvent.click(disabled);
    expect(onItemClick).not.toHaveBeenCalled();
    expect(action).not.toHaveBeenCalled();

    fireEvent.keyPress(disabled, { key: 'Enter', charCode: 13 });
    expect(onItemClick).not.toHaveBeenCalled();

    fireEvent.click(enabled);
    expect(onItemClick).toHaveBeenCalledTimes(1);
  });

  it('focuses the first enabled item when opened via keyboard', () => {
    const { container } = render(
      <DropdownMenu
        items={[
          { text: 'Muted', disabled: true },
          { text: 'Copy emoji', disabled: false },
        ]}
        onClose={jest.fn()}
        onItemClick={jest.fn()}
        openedViaKeyboard
      />,
    );

    const enabled = screen.getByRole('button', { name: 'Copy emoji' });
    expect(document.activeElement).toBe(enabled);
    expect(container.querySelector('.dropdown-menu__item--disabled')).not.toBeNull();
  });
});
