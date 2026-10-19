jest.mock('react-intl', () => ({ defineMessages: messages => messages }));
import { captureFilterAnchor, restoreFilterAnchor } from '../scroll_anchor';
import { FilterSurface } from '../surface';
import IntersectionObserverWrapper from '../../features/ui/util/intersection_observer_wrapper';

const setup = () => {
  const node = document.createElement('div');
  node.tabIndex = 0;
  const heights = Array(20).fill(100);
  node.getBoundingClientRect = () => ({ top: 10, bottom: 510, left: 10, right: 410, height: 500, width: 400 });
  const rows = heights.map((height, index) => {
    const row = document.createElement('article');
    row.dataset.id = String(index + 1);
    row.tabIndex = 0;
    row.getBoundingClientRect = () => {
      const top = 10 + heights.slice(0, index).reduce((sum, value) => sum + value, 0) - node.scrollTop;
      return { top, bottom: top + heights[index], height: heights[index] };
    };
    node.appendChild(row);
    return row;
  });
  document.body.appendChild(node);
  node.scrollTop = 350;
  return { node, rows, heights };
};

beforeEach(() => {
  jest.useFakeTimers();
  Object.defineProperty(document, 'hidden', { configurable: true, value: false });
});
afterEach(() => {
  document.body.innerHTML = '';
  jest.clearAllTimers(); jest.useRealTimers();
});

it('preserves the same pixel offset through hide and restoration above a reading row', () => {
  const { node, rows, heights } = setup();
  const before = rows[3].getBoundingClientRect().top;
  const anchor = captureFilterAnchor(node, node, 10);
  heights[1] = 0;
  restoreFilterAnchor(anchor, node, node, 10);
  expect(rows[3].getBoundingClientRect().top).toBe(before);
  const hidden = captureFilterAnchor(node, node, 10);
  heights[1] = 100;
  restoreFilterAnchor(hidden, node, node, 10);
  expect(rows[3].getBoundingClientRect().top).toBe(before);
});

it('uses the next stable row and moves focus there if the anchor itself is removed', () => {
  const { node, rows, heights } = setup();
  const button = document.createElement('button'); rows[3].appendChild(button); button.focus();
  const before = rows[4].getBoundingClientRect().top;
  const anchor = captureFilterAnchor(node, node, 10);
  rows[3].remove(); heights[3] = 0;
  restoreFilterAnchor(anchor, node, node, 10);
  expect(rows[4].getBoundingClientRect().top).toBe(before);
  expect(document.activeElement).toBe(rows[4]);
});

it.each(['wheel', 'touchstart', 'pointerdown', 'keydown'])('relinquishes an in-progress correction on deliberate %s input', event => {
  const { node, heights } = setup();
  const dispatch = jest.fn();
  const surface = new FilterSurface(dispatch, node, { ids: ['1', '2', '3'], scrollKey: 'route' });
  surface.prepare();
  expect(surface.frame).not.toBeNull();
  node.dispatchEvent(new Event(event));
  node.scrollTop = 400; heights[1] = 0;
  jest.advanceTimersByTime(100);
  expect(node.scrollTop).toBe(400);
  expect(surface.frame).toBeNull();
  surface.destroy();
});

it('cancels finite frames/listeners on teardown and skips media/menu locks', () => {
  const { node } = setup(); const dispatch = jest.fn();
  const surface = new FilterSurface(dispatch, node, { ids: ['1'], scrollKey: 'route', preventScroll: true });
  surface.prepare(); expect(surface.frame).toBeNull();
  surface.preventScroll = false; document.body.style.overflow = 'hidden';
  surface.prepare(); expect(surface.frame).toBeNull();
  document.body.style.overflow = '';
  surface.prepare(); expect(surface.frame).not.toBeNull();
  surface.destroy(); expect(surface.frame).toBeNull();
  expect(jest.getTimerCount()).toBe(0);
});

it('reconnects the existing article observer to a changed document/column root without losing callbacks', () => {
  const observers = [];
  global.IntersectionObserver = jest.fn().mockImplementation((callback, options) => {
    const observer = { callback, options, observe: jest.fn(), unobserve: jest.fn(), disconnect: jest.fn() };
    observers.push(observer); return observer;
  });
  const { node, rows } = setup(); const wrapper = new IntersectionObserverWrapper(); const callback = jest.fn();
  wrapper.observe('1', rows[0], callback);
  wrapper.connect({ root: node });
  wrapper.connect({ root: null });
  expect(observers[0].disconnect).toHaveBeenCalledTimes(1);
  expect(observers[1].observe).toHaveBeenCalledWith(rows[0]);
  observers[1].callback([{ target: rows[0] }]);
  expect(callback).toHaveBeenCalledTimes(1);
  wrapper.unobserve('1', rows[0]); wrapper.disconnect();
  expect(wrapper.nodes).toEqual({});
  expect(wrapper.callbacks).toEqual({});
});

it('reads logarithmically many rects even with 2000 retained rows', () => {
  const node = document.createElement('div');
  const read = jest.fn(index => ({ top: index * 100 - 150050, bottom: (index + 1) * 100 - 150050, height: 100 }));
  for (let i = 0; i < 2000; i++) {
    const row = document.createElement('article'); row.dataset.id = String(i + 1);
    row.getBoundingClientRect = () => read(i); node.appendChild(row);
  }
  const anchor = captureFilterAnchor(node, node, 0);
  expect(anchor.rows[0].node.dataset.id).toBe('1501');
  expect(anchor.rows[0].offset).toBe(-50);
  expect(read.mock.calls.length).toBeLessThanOrEqual(18);
});

it('does not assign scrollTop when the correction frames see no layout change', () => {
  const frames = [];
  const raf = jest.spyOn(window, 'requestAnimationFrame').mockImplementation(callback => {
    frames.push(callback);
    return frames.length;
  });
  const { node } = setup();
  let sets = 0;
  let top = 350;
  Object.defineProperty(node, 'scrollTop', {
    configurable: true,
    get: () => top,
    set (value) {
      sets += 1;
      top = Number(value) || 0;
    },
  });
  const surface = new FilterSurface(jest.fn(), node, { ids: ['1'], scrollKey: 'route' });
  surface.prepare();
  frames.shift()();
  frames.shift()();
  expect(sets).toBe(0);
  expect(top).toBe(350);
  surface.destroy();
  raf.mockRestore();
});

it.each([1, 0.75])('does not rewind %spx of inertia when the row rect only follows the scroll', (distance) => {
  const frames = [];
  const raf = jest.spyOn(window, 'requestAnimationFrame').mockImplementation(callback => {
    frames.push(callback);
    return frames.length;
  });
  const { node, rows } = setup();
  let sets = 0;
  let top = 350;
  Object.defineProperty(node, 'scrollTop', {
    configurable: true,
    get: () => top,
    set (value) {
      sets += 1;
      top = Number(value) || 0;
    },
  });
  const surface = new FilterSurface(jest.fn(), node, { ids: ['1'], scrollKey: 'route' });
  const before = rows[3].getBoundingClientRect().top;
  surface.prepare();
  top += distance;
  frames.shift()();
  frames.shift()();
  expect(sets).toBe(0);
  expect(top).toBe(350 + distance);
  expect(rows[3].getBoundingClientRect().top).toBe(before - distance);
  surface.destroy();
  raf.mockRestore();
});

it('still corrects a real row-height change when the scroller has not moved', () => {
  const frames = [];
  const raf = jest.spyOn(window, 'requestAnimationFrame').mockImplementation(callback => {
    frames.push(callback);
    return frames.length;
  });
  const { node, rows, heights } = setup();
  let sets = 0;
  let top = 350;
  Object.defineProperty(node, 'scrollTop', {
    configurable: true,
    get: () => top,
    set (value) {
      sets += 1;
      top = Number(value) || 0;
    },
  });
  const surface = new FilterSurface(jest.fn(), node, { ids: ['1'], scrollKey: 'route' });
  const before = rows[3].getBoundingClientRect().top;
  surface.prepare();
  heights[1] = 0;
  frames.shift()();
  frames.shift()();
  expect(sets).toBeGreaterThan(0);
  expect(rows[3].getBoundingClientRect().top).toBe(before);
  surface.destroy();
  raf.mockRestore();
});

it.each([
  ['touchmove', 'touchmove'],
  ['momentum after touchend', 'touchend'],
  ['scrollbar drag', null],
])('does not rewind a %s that moved the scroller after the snapshot', (_label, eventName) => {
  const frames = [];
  const raf = jest.spyOn(window, 'requestAnimationFrame').mockImplementation(callback => {
    frames.push(callback);
    return frames.length;
  });
  const { node } = setup();
  const surface = new FilterSurface(jest.fn(), node, { ids: ['1'], scrollKey: 'route' });
  surface.prepare();
  if (eventName) node.dispatchEvent(new Event(eventName));
  node.scrollTop = 900;
  frames.shift()();
  frames.shift()();
  expect(node.scrollTop).toBe(900);
  expect(surface.snapshot === null || surface.snapshot.abandoned).toBe(true);
  surface.destroy();
  raf.mockRestore();
});

it('keeps the original snapshot for multiple layout changes before the finite correction finishes', () => {
  const { node, rows, heights } = setup();
  const frames = [];
  const raf = jest.spyOn(window, 'requestAnimationFrame').mockImplementation(callback => {
    frames.push(callback); return frames.length;
  });
  const before = rows[3].getBoundingClientRect().top;
  const surface = new FilterSurface(jest.fn(), node, { ids: ['1'], scrollKey: 'route' });
  surface.prepare(); heights[0] = 0;
  surface.prepare(); heights[1] = 0;
  frames.shift()();
  surface.prepare(); heights[2] = 0;
  frames.shift()();
  expect(rows[3].getBoundingClientRect().top).toBe(before);
  expect(surface.frame).toBeNull();
  surface.destroy();
  raf.mockRestore();
});
