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
const placeholderHeights = container => (
  Array.from(container.querySelectorAll('.timeline-masonry__placeholder'))
    .map(node => parseFloat(node.style.height))
    .sort((a, b) => a - b)
);

describe('TimelineMasonry streaming upward-frontier insertion', () => {
  let width;
  let heights;
  let resizeObserverDescriptor;

  beforeEach(() => {
    width = 590;
    heights = { A: 90, B: 130, C: 70, D: 180, E: 100, F: 140, G: 120, latest: 90, 'media:1:0': 80 };
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

  it('captures and restores a tile on a delayed ResizeObserver measurement', () => {
    let observer;
    Object.defineProperty(window, 'ResizeObserver', {
      configurable: true,
      value: class {

        constructor (callback) {
          this.callback = callback;
          observer = this;
        }

        observe () {}

        unobserve () {}

        disconnect () {}

      },
    });

    const snapshot = { key: '.$A', top: -35 };
    const onCaptureLayoutAnchor = jest.fn(() => snapshot);
    const onRestoreLayoutAnchor = jest.fn();
    const { container } = render(
      <TimelineMasonry
        mode='card-3'
        onCaptureLayoutAnchor={onCaptureLayoutAnchor}
        onRestoreLayoutAnchor={onRestoreLayoutAnchor}
      >
        <article key='A'>A</article>
      </TimelineMasonry>,
    );
    const root = container.querySelector('.timeline-masonry');
    const tile = container.querySelector('.timeline-masonry__item');

    act(() => {
      observer.callback([{ target: root, contentRect: { width: 590, height: 0 } }]);
    });
    onCaptureLayoutAnchor.mockClear();
    onRestoreLayoutAnchor.mockClear();

    // The parent has not re-rendered; only Masonry's measured height changes.
    act(() => {
      observer.callback([{ target: tile, contentRect: { width: 190, height: 310 } }]);
    });
    expect(onCaptureLayoutAnchor).toHaveBeenCalledTimes(1);
    expect(onRestoreLayoutAnchor).toHaveBeenCalledWith(snapshot);

    // A duplicate measurement is ignored and must not adjust scroll again.
    act(() => {
      observer.callback([{ target: tile, contentRect: { width: 190, height: 310 } }]);
    });
    expect(onCaptureLayoutAnchor).toHaveBeenCalledTimes(1);
    expect(onRestoreLayoutAnchor).toHaveBeenCalledTimes(1);
  });

  it('does not move a lower tile while a height measurement is held for momentum', () => {
    let observer;
    let hold = false;
    Object.defineProperty(window, 'ResizeObserver', {
      configurable: true,
      value: class {

        constructor (callback) {
          this.callback = callback;
          observer = this;
        }

        observe () {}

        unobserve () {}

        disconnect () {}

      },
    });

    const ref = React.createRef();
    const onCaptureLayoutAnchor = jest.fn(() => ({ key: 'held', top: 12 }));
    function holdMeasurements () {
      return hold;
    }
    const onRestoreLayoutAnchor = jest.fn();
    const { container } = render(
      <TimelineMasonry
        ref={ref}
        mode='card-1'
        holdMeasurements={holdMeasurements}
        onCaptureLayoutAnchor={onCaptureLayoutAnchor}
        onRestoreLayoutAnchor={onRestoreLayoutAnchor}
      >
        <article key='A'>A</article>
        <article key='B'>B</article>
      </TimelineMasonry>,
    );
    const root = container.querySelector('.timeline-masonry');
    const tileA = item(container, 'A');
    const tileB = item(container, 'B');

    act(() => {
      observer.callback([
        { target: root, contentRect: { width: 320, height: 0 } },
        { target: tileA, contentRect: { width: 300, height: 100 } },
        { target: tileB, contentRect: { width: 300, height: 80 } },
      ]);
    });
    const before = position(container, 'B');
    onCaptureLayoutAnchor.mockClear();
    hold = true;

    act(() => {
      observer.callback([{ target: tileA, contentRect: { width: 300, height: 240 } }]);
    });

    expect(position(container, 'B')).toEqual(before);
    expect(onCaptureLayoutAnchor).not.toHaveBeenCalled();
    expect(ref.current.hasHeldMeasurements()).toBe(true);

    hold = false;
    act(() => {
      ref.current.flushHeldMeasurements();
    });

    expect(position(container, 'B').y).toBe(before.y + 140);
    expect(onCaptureLayoutAnchor).toHaveBeenCalledTimes(1);
  });

  it('extends all old columns once, then consumes headroom end-to-start without old-card reflow', () => {
    const { container, rerender } = render(cards(['A', 'B', 'C']));
    const original = ['A', 'B', 'C'].map(id => position(container, id));
    expect(original.map(place => place.y)).toEqual([0, 0, 0]);
    expect(original[0].x).toBeLessThan(original[1].x);
    expect(original[1].x).toBeLessThan(original[2].x);

    rerender(cards(['D', 'A', 'B', 'C']));
    expect(position(container, 'D')).toEqual({ x: original[2].x, y: 0 });
    expect(placeholderHeights(container)).toEqual([188, 188]);
    ['A', 'B', 'C'].forEach((id, index) => {
      expect(position(container, id)).toEqual({ x: original[index].x, y: 188 });
    });

    rerender(cards(['E', 'D', 'A', 'B', 'C']));
    expect(position(container, 'E')).toEqual({ x: original[1].x, y: 80 });
    expect(position(container, 'D').y).toBe(0);
    expect(placeholderHeights(container)).toEqual([80, 188]);
    expect(position(container, 'A').y).toBe(188);

    rerender(cards(['F', 'E', 'D', 'A', 'B', 'C']));
    expect(position(container, 'F')).toEqual({ x: original[0].x, y: 40 });
    expect(placeholderHeights(container)).toEqual([40, 80]);
    expect(position(container, 'A').y).toBe(188);

    rerender(cards(['G', 'F', 'E', 'D', 'A', 'B', 'C']));
    expect(position(container, 'G')).toEqual({ x: original[1].x, y: 0 });
    expect(position(container, 'F')).toEqual({ x: original[0].x, y: 88 });
    expect(position(container, 'E')).toEqual({ x: original[1].x, y: 128 });
    expect(position(container, 'D')).toEqual({ x: original[2].x, y: 48 });
    expect(placeholderHeights(container)).toEqual([48, 88]);
    ['A', 'B', 'C'].forEach((id, index) => {
      expect(position(container, id)).toEqual({ x: original[index].x, y: 236 });
    });
    expect(Array.from(container.querySelectorAll('.timeline-masonry__item article')).map(node => node.textContent)).toEqual([
      'G', 'F', 'E', 'D', 'A', 'B', 'C',
    ]);
    expect(Array.from(container.querySelectorAll('.timeline-masonry__placeholder')).every(node => node.getAttribute('aria-hidden') === 'true')).toBe(true);
  });

  it('matches sequential arrival when several cards are prepended in one batch', () => {
    const { container, rerender } = render(cards(['A', 'B', 'C']));
    const [start, middle, end] = ['A', 'B', 'C'].map(id => position(container, id).x);

    rerender(cards(['F', 'E', 'D', 'A', 'B', 'C']));
    expect(position(container, 'D')).toEqual({ x: end, y: 0 });
    expect(position(container, 'E')).toEqual({ x: middle, y: 80 });
    expect(position(container, 'F')).toEqual({ x: start, y: 40 });
    ['A', 'B', 'C'].forEach(id => expect(position(container, id).y).toBe(188));
    expect(placeholderHeights(container)).toEqual([40, 80]);
  });

  it('retains assigned columns across a later height change, resizing and a column-count reset', () => {
    const { container, rerender } = render(cards(['A', 'B', 'C'], 'media', 'medium'));
    const first = ['A', 'B', 'C'].map(id => position(container, id));

    rerender(cards(['D', 'A', 'B', 'C'], 'media', 'medium'));
    rerender(cards(['E', 'D', 'A', 'B', 'C'], 'media', 'medium'));
    expect(position(container, 'D').x).toBe(first[2].x);
    expect(position(container, 'E').x).toBe(first[1].x);

    heights.D = 330;
    act(() => {
      window.dispatchEvent(new Event('resize'));
    });
    expect(position(container, 'D').x).toBe(first[2].x);
    expect(position(container, 'E')).toEqual({ x: first[1].x, y: 230 });
    ['A', 'B', 'C'].forEach(id => {
      expect(position(container, id).y).toBe(338);
    });
    expect(placeholderHeights(container)).toEqual([230, 338]);

    width = 160;
    act(() => {
      window.dispatchEvent(new Event('resize'));
    });
    ['A', 'B', 'C', 'D', 'E'].forEach(id => {
      expect(position(container, id).x).toBe(0);
    });
    expect(placeholderHeights(container)).toEqual([]);
  });

  it('removes a tile without losing the cross-column reservation or reassigning survivors', () => {
    const { container, rerender } = render(cards(['A', 'B', 'C']));
    const original = ['A', 'B', 'C'].map(id => position(container, id));

    rerender(cards(['D', 'A', 'B', 'C']));
    rerender(cards(['D', 'A', 'B']));
    expect(position(container, 'D')).toEqual({ x: original[2].x, y: 0 });
    expect(position(container, 'A').y).toBe(188);
    expect(position(container, 'B').y).toBe(188);

    rerender(cards(['E', 'D', 'A', 'B']));
    expect(position(container, 'E')).toEqual({ x: original[1].x, y: 80 });
    expect(position(container, 'A').y).toBe(188);
    expect(placeholderHeights(container)).toEqual([80, 188]);
  });

  it('keeps a single column free of placeholders', () => {
    const { container, rerender } = render(cards(['A', 'B'], 'card-1'));
    rerender(cards(['C', 'A', 'B'], 'card-1'));
    expect(placeholderHeights(container)).toEqual([]);
    expect(position(container, 'C')).toEqual({ x: 0, y: 0 });
    expect(position(container, 'A').y).toBe(78);
  });

  it('keeps pinned posts above the shared prepend reservation', () => {
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
      expect(position(container, id).y).toBe(original[id].y + 188);
    });
    expect(placeholderHeights(container)).toEqual([188, 188]);
  });

  it('preserves full-width gaps in the old feed when reserving space above them', () => {
    const { container, rerender } = render(cards(['A', 'gap:123', 'B', 'C']));
    const previousGap = position(container, 'gap:123');
    const previousB = position(container, 'B');
    const middleColumn = position(container, 'C').x;

    rerender(cards(['D', 'A', 'gap:123', 'B', 'C']));
    expect(position(container, 'D').x).toBeGreaterThan(middleColumn);
    expect(position(container, 'D').y).toBe(0);
    expect(position(container, 'A').y).toBe(188);
    expect(position(container, 'gap:123').y).toBe(previousGap.y + 188);
    expect(position(container, 'B').y).toBe(previousB.y + 188);
  });

  it('aligns full-width gap boundaries inside the new reserved region', () => {
    const { container, rerender } = render(cards(['A', 'B', 'C']));
    rerender(cards(['latest', 'gap:123', 'media:1:0', 'A', 'B', 'C']));

    expect(position(container, 'latest').y).toBe(0);
    expect(position(container, 'gap:123')).toEqual({ x: 0, y: 98 });
    expect(position(container, 'media:1:0').y).toBe(206);
    ['A', 'B', 'C'].forEach(id => expect(position(container, id).y).toBe(294));
    expect(placeholderHeights(container)).toEqual([88, 88, 98, 98]);
  });

  it('resets column allocations for a disjoint timeline', () => {
    const { container, rerender } = render(cards(['A', 'B', 'C']));
    rerender(cards(['D', 'A', 'B', 'C']));
    rerender(cards(['X', 'Y', 'Z']));

    expect(position(container, 'X')).toEqual({ x: 0, y: 0 });
    expect(position(container, 'Y').y).toBe(0);
    expect(position(container, 'Z').y).toBe(0);
    expect(position(container, 'Y').x).toBeGreaterThan(position(container, 'X').x);
    expect(position(container, 'Z').x).toBeGreaterThan(position(container, 'Y').x);
    expect(placeholderHeights(container)).toEqual([]);
  });
});
