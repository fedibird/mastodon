import { insertionIndexForPoint, pointerPastThreshold, preferredDropIndex } from '../emoji_filter_drag';

const rect = (left, top, width, height) => ({
  left,
  top,
  right: left + width,
  bottom: top + height,
  width,
  height,
});

describe('emoji filter drag helpers', () => {
  it('starts a drag only after the pointer moves past the threshold', () => {
    const origin = { x: 10, y: 10 };

    expect(pointerPastThreshold(origin, { x: 16, y: 10 })).toBe(false);
    expect(pointerPastThreshold(origin, { x: 18, y: 10 })).toBe(true);
  });

  it('chooses the gap closest to the pointer', () => {
    const rects = [rect(0, 40, 90, 80), rect(100, 40, 90, 80)];

    expect(insertionIndexForPoint(rects, 10, 80)).toBe(0);
    expect(insertionIndexForPoint(rects, 95, 80)).toBe(1);
    expect(insertionIndexForPoint(rects, 180, 80)).toBe(2);
    expect(insertionIndexForPoint([], 10, 10)).toBe(0);
  });

  it('maps a visible drop index onto the full pinned list', () => {
    expect(preferredDropIndex(['🎉', '👍'], ['🎉', '👍'], 1, '❤️')).toBe(1);
    expect(preferredDropIndex(['🥳', '🎉', '👍'], ['🥳', '🎉', '👍'], 0, '👍')).toBe(0);
    expect(preferredDropIndex(['🎉', '👍', '❤️'], ['🎉', '❤️'], 1, '❤️')).toBe(2);
    expect(preferredDropIndex(['🎉', '👍'], [], 0, '❤️')).toBe(2);
  });
});
