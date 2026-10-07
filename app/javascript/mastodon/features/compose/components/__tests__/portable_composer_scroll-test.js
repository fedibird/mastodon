import { captureVisibleStatusAnchor, restoreVisibleStatusAnchor } from '../portable_composer_scroll';

const box = (top, bottom) => ({
  top,
  bottom,
  left: 0,
  width: 320,
  height: Math.max(0, bottom - top),
  right: 320,
  x: 0,
  y: top,
  toJSON () {},
});

const buildColumn = (label) => {
  const column = document.createElement('div');
  column.className = 'column';
  column.setAttribute('aria-label', label);
  column.innerHTML = '<div class="scrollable"><article data-id="100"></article><article data-id="90"></article></div>';
  const scroller = column.querySelector('.scrollable');

  Object.defineProperty(scroller, 'scrollHeight', { configurable: true, value: 2400 });
  Object.defineProperty(scroller, 'clientHeight', { configurable: true, value: 500 });
  scroller.getBoundingClientRect = () => box(0, 500);
  column.querySelectorAll('article').forEach(article => {
    article.getBoundingClientRect = () => box(80, 140);
  });
  document.body.appendChild(column);

  return column;
};

describe('portable composer scroll anchor', () => {
  afterEach(() => {
    document.body.innerHTML = '';
  });

  it('restores only the column node it captured when labels match', () => {
    const columnA = buildColumn('#ruby');
    const columnB = buildColumn('#ruby');
    const scrollerA = columnA.querySelector('.scrollable');
    const scrollerB = columnB.querySelector('.scrollable');

    scrollerA.scrollTop = 500;
    scrollerB.scrollTop = 700;
    columnB.querySelector('article').getBoundingClientRect = () => box(80, 140);

    const anchor = captureVisibleStatusAnchor(columnB);

    columnB.querySelectorAll('article').forEach(article => {
      article.getBoundingClientRect = () => box(240, 300);
    });
    restoreVisibleStatusAnchor(anchor);

    expect(anchor.column).toBe(columnB);
    expect(anchor.id).toBe('100');
    expect(anchor.offset).toBe(80);
    expect(scrollerA.scrollTop).toBe(500);
    expect(scrollerB.scrollTop).toBe(860);
  });

  it('skips a column that is no longer connected', () => {
    const column = buildColumn('Friends');
    const scroller = column.querySelector('.scrollable');

    scroller.scrollTop = 400;
    const anchor = captureVisibleStatusAnchor(column);

    column.remove();
    column.querySelector('article').getBoundingClientRect = () => box(400, 460);
    restoreVisibleStatusAnchor(anchor);

    expect(column.isConnected).toBe(false);
    expect(captureVisibleStatusAnchor(column)).toBeNull();
    expect(scroller.scrollTop).toBe(400);
  });
});
