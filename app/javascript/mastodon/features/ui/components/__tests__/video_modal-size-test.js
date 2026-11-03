/* eslint-disable react/prop-types */

import { render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

jest.mock('mastodon/features/video', () => ({ width, height }) => (
  <div data-testid='standalone-video' data-width={width} data-height={height} />
));
jest.mock('mastodon/features/picture_in_picture/components/footer', () => () => null);
jest.mock('mastodon/blurhash', () => ({
  getAverageFromBlurhash: () => null,
}));

import VideoModal from '../video_modal';

const renderVideo = media => {
  const store = createStore(() => fromJS({ statuses: {} }));
  render(
    <Provider store={store}>
      <VideoModal
        media={fromJS(media)}
        onClose={jest.fn()}
        onChangeBackgroundColor={jest.fn()}
      />
    </Provider>,
  );
};

describe('VideoModal sizing', () => {
  it('passes the original video dimensions to the player', () => {
    renderVideo({
      type: 'video',
      url: 'https://example.test/clip.mp4',
      meta: {
        original: { width: 1920, height: 1080 },
        small: { width: 160, height: 90 },
      },
    });

    expect(screen.getByTestId('standalone-video')).toHaveAttribute('data-width', '1920');
    expect(screen.getByTestId('standalone-video')).toHaveAttribute('data-height', '1080');
  });

  it('does not leave a metadata-free video at the browser default of 300x150', () => {
    renderVideo({ type: 'video', url: 'https://example.test/no-metadata.mp4' });

    expect(screen.getByTestId('standalone-video')).toHaveAttribute('data-width', '960');
    expect(screen.getByTestId('standalone-video')).toHaveAttribute('data-height', '540');
  });
});
