/* eslint-disable react/prop-types */

import { render } from '@testing-library/react';
import React from 'react';

jest.mock('../icon_button', () => ({ title }) => <button type='button' title={title} />);

jest.mock('react-overlays/Overlay', () => {
  const MockOverlay = props => {
    MockOverlay.popperConfig = props.popperConfig;
    return null;
  };

  return MockOverlay;
});

import Dropdown from '../dropdown_menu';
import Overlay from 'react-overlays/Overlay';

const viewportPopperConfig = {
  strategy: 'fixed',
  modifiers: [
    {
      name: 'preventOverflow',
      options: {
        boundary: 'viewport',
        altAxis: true,
        padding: 8,
      },
    },
    {
      name: 'flip',
      options: {
        boundary: 'viewport',
        padding: 8,
      },
    },
  ],
};

const renderDropdown = scrollable => render(
  <Dropdown
    items={[{ text: 'Edit', action: jest.fn() }]}
    onOpen={jest.fn()}
    onClose={jest.fn()}
    scrollable={scrollable}
  />,
);

describe('Dropdown popper config', () => {
  it('keeps the pre-existing fixed strategy when the menu is not scrollable', () => {
    renderDropdown(false);

    expect(Overlay.popperConfig).toEqual({ strategy: 'fixed' });

    render(
      <Dropdown
        items={[{ text: 'Edit', action: jest.fn() }]}
        onOpen={jest.fn()}
        onClose={jest.fn()}
      />,
    );

    expect(Overlay.popperConfig).toEqual({ strategy: 'fixed' });
  });

  it('passes viewport modifiers only when the menu is scrollable', () => {
    renderDropdown(true);

    expect(Overlay.popperConfig).toEqual(viewportPopperConfig);
  });
});
