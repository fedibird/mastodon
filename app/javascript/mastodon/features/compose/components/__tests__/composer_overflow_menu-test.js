import { fireEvent, render, screen } from '@testing-library/react';
import React from 'react';

jest.mock('react-intl', () => ({
  FormattedNumber: () => null,
  defineMessages: messages => messages,
}));

import ComposerOverflowMenu from '../composer_overflow_menu';

describe('ComposerOverflowMenu', () => {
  it('closes only the menu whose own panel was not clicked', () => {
    render(
      <div>
        <ComposerOverflowMenu label='More actions primary'>
          <button type='button'>Primary schedule</button>
        </ComposerOverflowMenu>
        <ComposerOverflowMenu label='More actions portable'>
          <button type='button'>Portable schedule</button>
        </ComposerOverflowMenu>
      </div>,
    );

    fireEvent.click(screen.getByRole('button', { name: 'More actions primary' }));
    screen.getByRole('button', { name: 'More actions portable' }).dispatchEvent(new MouseEvent('click', { bubbles: true }));

    const panels = screen.getAllByTestId('composer-overflow-menu');
    const portablePanel = panels.find(panel => panel.textContent.includes('Portable schedule'));
    const primaryPanel = panels.find(panel => panel.textContent.includes('Primary schedule'));

    fireEvent.mouseDown(portablePanel);

    expect(screen.queryByText('Primary schedule')).toBeNull();
    expect(screen.getByText('Portable schedule')).toBeTruthy();
    expect(primaryPanel.isConnected).toBe(false);

    fireEvent.mouseDown(document.body);

    expect(screen.queryByText('Portable schedule')).toBeNull();
  });

  it('closes when a touch ends outside the menu', () => {
    render(
      <ComposerOverflowMenu label='More actions'>
        <button type='button'>Schedule</button>
      </ComposerOverflowMenu>,
    );

    fireEvent.click(screen.getByRole('button', { name: 'More actions' }));
    expect(screen.getByText('Schedule')).toBeTruthy();

    fireEvent.touchEnd(document.body);

    expect(screen.queryByText('Schedule')).toBeNull();
  });
});
