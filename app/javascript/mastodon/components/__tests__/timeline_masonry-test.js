import { act, render } from '@testing-library/react';
import React from 'react';

import TimelineMasonry from '../timeline_masonry';

const rect = (width, height) => ({ width, height, x: 0, y: 0, top: 0, left: 0, right: width, bottom: height });
const cards = (keys, mode = 'card-3', mediaSize) => (
  <TimelineMasonry mode={mode} mediaSize={mediaSize}>
    {keys.map(key => <article key={key}>{key}</article>)}
  </TimelineMasonry>
);

const item = (container, id) => (
  Array.from(container.querySelectorAll('.timeline-masonry__item')).find(node => node.textContent === id)
);
const position = (container, id) => {
  const node = item(container, id);
  const match = node.style.transform.match(/translate3d\(0, ([\d.]+)px, 0\)/);
  return {
    x: parseFloat(node.style.insetInlineStart),
    y: Number(match[1]),
  };
};

describe('TimelineMasonry streaming shortest-column insertion', () => {
  let width;
  let heights;
  let resizeObserverDescriptor;

  beforeEach(() => {
    width = 590;
    heights = { A: 90, B: 130, C: 70, D: 180, E: 100, F: 140, G: 120 };
    resizeObserverDescriptor = Object.getOwnPropertyDescriptor(window, 'ResizeObserver');
    Object.defineProperty(window, 'ResizeObserver', { configurable: true, value: undefined });

    jest.spyOn(Element.prototype, 'getBoundingClientRect').mockImplementation(function () {
      if (this.classList.contains('timeline-masonry')) {
        return rect(width, 0);
      }
      if (this.hasAttribute('data-layout-key')) {
        return rect(0, heights[this.textContent] || 100);
      }
      return rect(0, 0);
    });
  });

  afterEach(() => {
    jest.restoreAllMocks();
    if (resizeObserverDescriptor) {
      Object.defineProperty(window, 'ResizeObserver', resizeObserverDescriptor);
    } else {
      delete window.ResizeObserver;
    }
  });

  it('prepends into the shortest column, breaking ties toward inline-end, with no reserved-row gaps', () => {
    const { container, rerender } = render(cards(['A', 'B', 'C']));
    const original = ['A', 'B', 'C'].map(id => position(container, id));
    expect(original.map(place => place.y)).toEqual([0, 0, 0]);
    expect(original[0].x).toBeLessThan(original[1].x);
    expect(original[1].x).toBeLessThan(original[2].x);

    rerender(cards(['D', 'A', 'B', 'C']));
    expect(position(container, 'D')).toEqual({ x: original[2].x, y: 0 });
    expect(position(container, 'C')).toEqual({ x: original[2].x, y: 188 });
    expect(position(container, 'A')).toEqual(original[0]);
    expect(position(container, 'B')).toEqual(original[1]);

    rerender(cards(['E', 'D', 'A', 'B', 'C']));
    expect(position(container, 'E')).toEqual({ x: original[0].x, y: 0 });
    expect(position(container, 'A')).toEqual({ x: original[0].x, y: 108 });
    expect(position(container, 'C').y).toBe(188);

    rerender(cards(['F', 'E', 'D', 'A', 'B', 'C']));
    expect(position(container, 'F')).toEqual({ x: original[1].x, y: 0 });
    expect(position(container, 'B')).toEqual({ x: original[1].x, y: 148 });

    rerender(cards(['G', 'F', 'E', 'D', 'A', 'B', 'C']));
    expect(position(container, 'G')).toEqual({ x: original[0].x, y: 0 });
    expect(position(container, 'E').y).toBe(128);
    expect(position(container, 'A').y).toBe(236);
    expect(position(container, 'B').y).toBe(148);
    expect(position(container, 'C').y).toBe(188);
    expect(container.querySelectorAll('.timeline-masonry__placeholder')).toHaveLength(0);
    expect(Array.from(container.querySelectorAll('.timeline-masonry__item article')).map(node => node.textContent)).toEqual([
      'G', 'F', 'E', 'D', 'A', 'B', 'C',
    ]);
  });

  it('places a batch oldest-first rather than making a separate top row', () => {
    const { container, rerender } = render(cards(['A', 'B', 'C']));
    const [start, middle, end] = ['A', 'B', 'C'].map(id => position(container, id).x);

    rerender(cards(['F', 'E', 'D', 'A', 'B', 'C']));
    expect(position(container, 'D')).toEqual({ x: end, y: 0 });
    expect(position(container, 'E')).toEqual({ x: start, y: 0 });
    expect(position(container, 'F')).toEqual({ x: middle, y: 0 });
    expect(position(container, 'A').y).toBe(108);
    expect(position(container, 'B').y).toBe(148);
    expect(position(container, 'C').y).toBe(188);
    expect(container.querySelectorAll('.timeline-masonry__placeholder')).toHaveLength(0);
  });

  it('keeps the assigned column when media heights change, and resets on column count changes', () => {
    const { container, rerender } = render(cards(['A', 'B', 'C'], 'media', 'medium'));
    const first = ['A', 'B', 'C'].map(id => position(container, id));

    rerender(cards(['D', 'A', 'B', 'C'], 'media', 'medium'));
    rerender(cards(['E', 'D', 'A', 'B', 'C'], 'media', 'medium'));
    expect(position(container, 'D').x).toBe(first[2].x);
    expect(position(container, 'E').x).toBe(first[0].x);

    heights.D = 330;
    act(() => { window.dispatchEvent(new Event('resize')); });
    expect(position(container, 'D').x).toBe(first[2].x);
    expect(position(container, 'C').y).toBe(338);
    expect(position(container, 'A').y).toBe(108);
    expect(position(container, 'B').y).toBe(0);

    width = 160;
    act(() => { window.dispatchEvent(new Event('resize')); });
    ['A', 'B', 'C', 'D', 'E'].forEach(id => {
      expect(position(container, id).x).toBe(0);
    });
    expect(container.querySelectorAll('.timeline-masonry__placeholder')).toHaveLength(0);
  });

  it('keeps a single column free of placeholders', () => {
    const { container, rerender } = render(cards(['A', 'B'], 'card-1'));
    rerender(cards(['C', 'A', 'B'], 'card-1'));
    expect(container.querySelectorAll('.timeline-masonry__placeholder')).toHaveLength(0);
    expect(position(container, 'C')).toEqual({ x: 0, y: 0 });
    expect(position(container, 'A').y).toBe(78);
  });

  it('keeps pinned posts above live columns and preserves unrelated older positions', () => {
    const pinned = 'f-Pinned';
    const { container, rerender } = render(cards([pinned, 'A', 'B', 'C']));
    const original = {
      pinned: position(container, pinned),
      A: position(container, 'A'),
      B: position(container, 'B'),
      C: position(container, 'C'),
    };

    rerender(cards([pinned, 'D', 'A', 'B', 'C']));
    expect(position(container, pinned)).toEqual(original.pinned);
    expect(position(container, 'D')).toEqual({ x: original.C.x, y: 108 });
    expect(position(container, 'A')).toEqual(original.A);
    expect(position(container, 'B')).toEqual(original.B);
    expect(position(container, 'C').y).toBe(original.C.y + 188);
  });

  it('uses the heights above a full-width gap, not older columns below it', () => {
    const { container, rerender } = render(cards(['A', 'gap:123', 'B', 'C']));
    const previousGap = position(container, 'gap:123');
    const previousB = position(container, 'B');
    const end = position(container, 'C').x;

    rerender(cards(['D', 'A', 'gap:123', 'B', 'C']));
    expect(position(container, 'D')).toEqual({ x: end, y: 0 });
    expect(position(container, 'A').y).toBe(0);
    expect(position(container, 'gap:123').y).toBe(previousGap.y + 90);
    expect(position(container, 'B').y).toBe(previousB.y + 90);
  });

  it('discards column assignments after switching to a disjoint timeline', () => {
    const { container, rerender } = render(cards(['A', 'B', 'C']));
    rerender(cards(['D', 'A', 'B', 'C']));
    rerender(cards(['X', 'Y', 'Z']));

    expect(position(container, 'X')).toEqual({ x: 0, y: 0 });
    expect(position(container, 'Y').y).toBe(0);
    expect(position(container, 'Z').y).toBe(0);
    expect(position(container, 'Y').x).toBeGreaterThan(position(container, 'X').x);
    expect(position(container, 'Z').x).toBeGreaterThan(position(container, 'Y').x);
  });
});
