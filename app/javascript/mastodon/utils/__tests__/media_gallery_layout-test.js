import { fromJS } from 'immutable';
import { mediaGalleryAspectRatio } from '../media_gallery_layout';

describe('responsive media gallery aspect ratio', () => {
  const portrait = fromJS([{ id: 'image', type: 'image', meta: { small: { aspect: 0.5 } } }]);

  it('reserves the standard 16:9 crop before any width is measured', () => {
    expect(mediaGalleryAspectRatio(portrait)).toBeCloseTo(16 / 9);
    expect(mediaGalleryAspectRatio(portrait, { crop: true })).toBeCloseTo(16 / 9);
  });

  it('reserves the original ratio for uncropped cards and post details', () => {
    expect(mediaGalleryAspectRatio(portrait, { crop: false })).toBeCloseTo(0.5);
    expect(mediaGalleryAspectRatio(portrait, { standalone: true })).toBeCloseTo(0.5);
  });

  it('falls back to 16:9 for missing or invalid media metadata', () => {
    const noAspect = fromJS([{ id: 'image', type: 'image' }]);
    const invalid = portrait.setIn([0, 'meta', 'small', 'aspect'], -5);

    expect(mediaGalleryAspectRatio(noAspect, { crop: false })).toBeCloseTo(16 / 9);
    expect(mediaGalleryAspectRatio(invalid, { crop: false })).toBeCloseTo(16 / 9);
  });

  it('retains the preexisting quote and large-gallery geometry adjustments', () => {
    expect(mediaGalleryAspectRatio(portrait, { crop: false, quote: true })).toBeCloseTo(1);
    const six = fromJS(Array.from({ length: 6 }, (_, id) => ({ id: String(id), type: 'image' })));
    expect(mediaGalleryAspectRatio(six, { maxAttachments: 6 })).toBeCloseTo((16 / 9) / 1.5);
  });
});
