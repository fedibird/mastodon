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
  return render(
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

  it('sets an enlarged frame before playback, even for a 160px source', () => {
    const { container } = renderVideo({
      type: 'video',
      url: 'https://example.test/low-res.mp4',
      preview_url: 'https://example.test/thumbnail.jpg',
      meta: { original: { width: 160, height: 90 } },
    });
    const frame = container.querySelector('.video-modal__container');

    expect(frame.style.getPropertyValue('--modal-video-aspect')).toBe('160 / 90');
    expect(frame.style.getPropertyValue('--modal-video-width-by-height')).toBe('142.222vh');
    expect(screen.getByTestId('standalone-video')).toHaveAttribute('data-width', '160');
  });

  it('uses a portrait-sized frame for portrait video instead of landscape fallback', () => {
    const { container } = renderVideo({
      type: 'video',
      meta: { original: { width: 720, height: 1280 } },
    });

    expect(container.querySelector('.video-modal__container').style.getPropertyValue('--modal-video-width-by-height')).toBe('45vh');
  });

  it('does not leave a metadata-free video at the browser default of 300x150', () => {
    renderVideo({ type: 'video', url: 'https://example.test/no-metadata.mp4' });

    expect(screen.getByTestId('standalone-video')).toHaveAttribute('data-width', '960');
    expect(screen.getByTestId('standalone-video')).toHaveAttribute('data-height', '540');
  });
});
