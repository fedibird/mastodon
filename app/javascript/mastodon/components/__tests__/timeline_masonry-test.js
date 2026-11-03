import { act, render } from '@testing-library/react';
import React from 'react';

import TimelineMasonry from '../timeline_masonry';

const heights = {
  A: 90, B: 130, C: 70, D: 180, E: 100, F: 140, G: 120,
};
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

describe('TimelineMasonry streaming insertion', () => {
  let width;
  let resizeObserverDescriptor;

  beforeEach(() => {
    width = 590;
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

  it('places new cards end-to-start without reflowing earlier column assignments', () => {
    const { container, rerender } = render(cards(['A', 'B', 'C']));
    const original = ['A', 'B', 'C'].map(id => position(container, id));
    expect(original.map(place => place.y)).toEqual([0, 0, 0]);
    expect(original[0].x).toBeLessThan(original[1].x);
    expect(original[1].x).toBeLessThan(original[2].x);

    rerender(cards(['D', 'A', 'B', 'C']));
    expect(position(container, 'D')).toEqual({ x: original[2].x, y: 0 });
    expect(container.querySelectorAll('.timeline-masonry__placeholder')).toHaveLength(2);
    ['A', 'B', 'C'].forEach((id, index) => {
      expect(position(container, id)).toEqual({ x: original[index].x, y: 188 });
    });

    rerender(cards(['E', 'D', 'A', 'B', 'C']));
    expect(position(container, 'E')).toEqual({ x: original[1].x, y: 0 });
    expect(position(container, 'D').y).toBe(0);
    expect(position(container, 'A').y).toBe(188);
    expect(container.querySelectorAll('.timeline-masonry__placeholder')).toHaveLength(2);

    rerender(cards(['F', 'E', 'D', 'A', 'B', 'C']));
    expect(position(container, 'F')).toEqual({ x: original[0].x, y: 0 });
    expect(position(container, 'A').y).toBe(188);

    rerender(cards(['G', 'F', 'E', 'D', 'A', 'B', 'C']));
    expect(position(container, 'G')).toEqual({ x: original[2].x, y: 0 });
    expect(position(container, 'D').y).toBe(128);
    expect(position(container, 'A').y).toBe(316);
    expect(Array.from(container.querySelectorAll('.timeline-masonry__item article')).map(node => node.textContent)).toEqual([
      'G', 'F', 'E', 'D', 'A', 'B', 'C',
    ]);
    expect(container.querySelectorAll('.timeline-masonry__placeholder[aria-hidden="true"]').length).toBeGreaterThan(0);
  });

  it('reserves blank space under shorter cards and resets on column count change', () => {
    const { container, rerender } = render(cards(['A', 'B', 'C'], 'media', 'medium'));

    rerender(cards(['D', 'A', 'B', 'C'], 'media', 'medium'));
    rerender(cards(['E', 'D', 'A', 'B', 'C'], 'media', 'medium'));

    const placeholders = Array.from(container.querySelectorAll('.timeline-masonry__placeholder'));
    expect(placeholders.map(node => parseFloat(node.style.height)).sort((a, b) => a - b)).toEqual([80, 180]);
    expect(position(container, 'E').x).toBeLessThan(position(container, 'D').x);

    width = 350;
    act(() => {
      window.dispatchEvent(new Event('resize'));
    });
    expect(container.querySelectorAll('.timeline-masonry__placeholder')).toHaveLength(0);
    expect(position(container, 'D').x).toBe(0);
    expect(position(container, 'E').x).toBe(0);
  });

  it('keeps a single card column free of reserved rows', () => {
    const { container, rerender } = render(cards(['A', 'B'], 'card-1'));
    rerender(cards(['C', 'A', 'B'], 'card-1'));
    expect(container.querySelectorAll('.timeline-masonry__placeholder')).toHaveLength(0);
    expect(position(container, 'C').x).toBe(0);
  });
  it('keeps pinned posts above streaming rows and preserves the older cards', () => {
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
    ['A', 'B', 'C'].forEach(id => {
      expect(position(container, id).x).toBe(original[id].x);
      expect(position(container, id).y - original[id].y).toBe(188);
    });
  });

});
