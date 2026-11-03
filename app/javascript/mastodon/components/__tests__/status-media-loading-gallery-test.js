/* eslint-disable react/prop-types */
import { render } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';

jest.mock('mastodon/initial_state', () => ({
  displayMedia: 'show_all',
  cropImages: true,
  maxAttachments: 4,
}));

// Keep the async media module unloaded so the skeleton itself is inspected.
jest.mock('../../features/ui/components/bundle', () => {
  const ReactMock = require('react');
  return ({ loading: Loading }) => ReactMock.createElement(Loading);
});

import StatusMediaStack from '../status_media';

const portrait = fromJS([{
  id: 'image',
  type: 'image',
  meta: { small: { aspect: 0.5 } },
}]);

describe('StatusMediaStack lazy-loading gallery geometry', () => {
  it('uses 16:9 for a standard post before the gallery module arrives', () => {
    const { container } = render(<StatusMediaStack media={portrait} height={110} visible />);
    const skeleton = container.querySelector('.media-gallery');

    expect(skeleton).not.toBeNull();
    expect(Number(skeleton.style.aspectRatio)).toBeCloseTo(16 / 9);
    expect(skeleton.style.height).toBe('');
  });

  it('uses the independent original ratio for an uncropped card skeleton', () => {
    const { container } = render(<StatusMediaStack media={portrait} height={160} visible cropImages={false} />);
    expect(Number(container.querySelector('.media-gallery').style.aspectRatio)).toBeCloseTo(0.5);
  });

  it('keeps the standalone detail ratio regardless of the regular crop setting', () => {
    const { container } = render(<StatusMediaStack media={portrait} height={110} visible standalone cropImages />);
    expect(Number(container.querySelector('.media-gallery').style.aspectRatio)).toBeCloseTo(0.5);
  });
});
