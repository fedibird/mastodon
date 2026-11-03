/* eslint-disable react/prop-types */

import { render } from '@testing-library/react';
import React from 'react';

jest.mock('../timeline_masonry', () => {
  const ReactMock = require('react');
  return ({ children, mediaSize }) => ReactMock.createElement(
    'div',
    { 'data-layout': 'masonry', 'data-size': mediaSize },
    children,
  );
});

import MediaItemsLayout from '../media_items_layout';

describe('media items presentation layouts', () => {
  it('uses square CSS grid with the chosen minimum size', () => {
    const { container } = render(
      <MediaItemsLayout shape='square' size='small'><div data-testid='tile' /></MediaItemsLayout>,
    );
    expect(container.querySelector('.timeline-media-grid').style.gridTemplateColumns).toContain('126px');
    expect(container.querySelector('[data-testid="tile"]')).toBeInTheDocument();
  });

  it('forces one square column for maximum size', () => {
    const { container } = render(
      <MediaItemsLayout shape='square' size='max'><div data-testid='tile' /></MediaItemsLayout>,
    );
    expect(container.querySelector('.timeline-media-grid').style.gridTemplateColumns).toBe('minmax(0, 1fr)');
  });

  it('uses measured Masonry when original aspect ratio is selected', () => {
    const { container } = render(
      <MediaItemsLayout shape='original' size='large'><div data-testid='tile' /></MediaItemsLayout>,
    );
    expect(container.querySelector('[data-layout="masonry"]')).toHaveAttribute('data-size', 'large');
    expect(container.querySelector('[data-testid="tile"]')).toBeInTheDocument();
  });
});
