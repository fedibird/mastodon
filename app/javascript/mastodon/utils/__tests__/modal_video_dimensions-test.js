import { fromJS } from 'immutable';
import { modalVideoDimensions, modalVideoFrameStyle } from '../modal_video_dimensions';

describe('lightbox video dimensions', () => {
  it('uses original video dimensions instead of the top-level or preview dimensions', () => {
    const attachment = fromJS({
      width: 320,
      height: 180,
      meta: {
        original: { width: 1920, height: 1080 },
        small: { width: 160, height: 90 },
      },
    });

    expect(modalVideoDimensions(attachment)).toEqual({ width: 1920, height: 1080 });
  });

  it('preserves the dimensions of a portrait video', () => {
    const attachment = fromJS({ meta: { original: { width: 720, height: 1280 } } });

    expect(modalVideoDimensions(attachment)).toEqual({ width: 720, height: 1280 });
  });

  it('accepts legacy top-level dimensions when original metadata is unavailable', () => {
    const attachment = fromJS({ width: 1280, height: 720 });

    expect(modalVideoDimensions(attachment)).toEqual({ width: 1280, height: 720 });
  });

  it('scales preview-only metadata instead of showing a thumbnail-sized player', () => {
    const attachment = fromJS({ meta: { small: { width: 128, height: 256 } } });

    expect(modalVideoDimensions(attachment)).toEqual({ width: 960, height: 1920 });
  });

  it('honors aspect-only metadata when no width/height is provided', () => {
    const attachment = fromJS({ meta: { original: { aspect: 0.5625 } } });

    expect(modalVideoDimensions(attachment)).toEqual({ width: 960, height: 1707 });
  });

  it('reserves a larger player independently of original pixel resolution', () => {
    expect(modalVideoFrameStyle({ width: 160, height: 90 })).toEqual({
      '--modal-video-aspect': '160 / 90',
      '--modal-video-width-by-height': '142.222vh',
    });
    expect(modalVideoFrameStyle({ width: 720, height: 1280 })).toEqual({
      '--modal-video-aspect': '720 / 1280',
      '--modal-video-width-by-height': '45vh',
    });
  });

  it('uses a usable fallback for missing or invalid dimensions', () => {
    expect(modalVideoDimensions(fromJS({}))).toEqual({ width: 960, height: 540 });
    expect(modalVideoDimensions(fromJS({
      meta: { original: { width: 0, height: -1 }, small: { width: 0, height: 0 } },
    }))).toEqual({ width: 960, height: 540 });
  });
});
