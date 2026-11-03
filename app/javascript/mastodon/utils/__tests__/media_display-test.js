import { fromJS } from 'immutable';

jest.mock('mastodon/initial_state', () => ({
  displayMedia: 'default',
}));

import {
  MEDIA_SHAPES,
  MEDIA_SIZES,
  MEDIA_VISIBILITY,
  defaultMediaVisibility,
  mediaIsConcealed,
  mediaAspectRatio,
  mediaColumnsForWidth,
  mediaGridColumns,
} from '../media_display';

describe('local media presentation', () => {
  it('exposes two shapes, four sizes and three temporary visibility policies', () => {
    expect(MEDIA_SHAPES).toEqual(['square', 'original']);
    expect(MEDIA_SIZES).toEqual(['small', 'medium', 'large', 'max']);
    expect(MEDIA_VISIBILITY).toEqual(['hide_sensitive', 'show_all', 'hide_all']);
    expect(defaultMediaVisibility()).toBe('hide_sensitive');
  });

  it.each([
    ['hide_sensitive', false, false, false, false],
    ['hide_sensitive', true, false, false, true],
    ['hide_sensitive', false, true, false, true],
    ['hide_sensitive', true, false, true, false],
    ['show_all', true, true, false, false],
    ['hide_all', false, false, false, true],
    ['hide_all', true, false, true, false],
  ])('visibility %s sensitive=%s cw=%s revealed=%s returns conceal=%s',
    (policy, sensitive, cwHidden, revealed, expected) => {
      expect(mediaIsConcealed(policy, sensitive, cwHidden, revealed)).toBe(expected);
    });

  it('shrinks to fit, with max always one column', () => {
    expect(mediaColumnsForWidth('small', 320)).toBe(2);
    expect(mediaColumnsForWidth('medium', 320)).toBe(1);
    expect(mediaColumnsForWidth('large', 600)).toBe(2);
    expect(mediaColumnsForWidth('max', 1200)).toBe(1);
    expect(mediaColumnsForWidth('large', 100)).toBe(1);
    expect(mediaGridColumns('max')).toBe('minmax(0, 1fr)');
    expect(mediaGridColumns('small')).toContain('min(100%, 126px)');
  });

  it('uses original media aspect ratio for natural-height Masonry tiles', () => {
    expect(mediaAspectRatio(fromJS({ meta: { original: { aspect: 1.5 } } }))).toBe(1.5);
    expect(mediaAspectRatio(fromJS({ meta: { original: { width: 300, height: 600 } } }))).toBe(0.5);
    expect(mediaAspectRatio(fromJS({ meta: { small: { aspect: 0.75 } } }))).toBe(0.75);
    expect(mediaAspectRatio(fromJS({ meta: { original: { width: 300, height: 0 } } }))).toBeNull();
  });
});
