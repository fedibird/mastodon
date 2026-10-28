import { act } from '@testing-library/react';

class FakeResizeObserver {

  constructor (callback) {
    this.callback = callback;
    this.elements = [];
    FakeResizeObserver.instances.push(this);
  }

  observe (element) {
    if (!this.elements.includes(element)) {
      this.elements.push(element);
    }
  }

  unobserve () {}

  disconnect () {}

}

FakeResizeObserver.instances = [];
global.ResizeObserver = FakeResizeObserver;

const {
  openSession,
  pinSession,
  registerAnchor,
  registerDockSlot,
  resetExternalPlayersForTests,
} = require('../session');

const PLAYER = 'https://player.example/embed/fixture';
const originalRect = HTMLElement.prototype.getBoundingClientRect;
const boxes = new WeakMap();

const box = (top, height = 110) => ({
  top,
  left: 10,
  right: 330,
  bottom: top + height,
  width: 320,
  height,
  x: 10,
  y: top,
});

const flushLayout = async () => {
  await act(async () => {
    await new Promise((resolve) => {
      setTimeout(resolve, 30);
    });
  });
};

describe('external player layout watch', () => {
  beforeEach(() => {
    boxes.set(document.documentElement, box(0, 800));
    boxes.set(document.body, box(0, 800));
    HTMLElement.prototype.getBoundingClientRect = function () {
      return boxes.get(this) || box(0, 800);
    };
    window.innerWidth = 1000;
    window.innerHeight = 800;
  });

  afterEach(() => {
    HTMLElement.prototype.getBoundingClientRect = originalRect;
    resetExternalPlayersForTests();
    FakeResizeObserver.instances = [];
  });

  it('moves the iframe when an ancestor resizes and the anchor only changes position', async () => {
    const list = document.createElement('div');
    list.className = 'item-list';
    const above = document.createElement('article');
    const anchor = document.createElement('div');
    anchor.className = 'external-embed-player__frame';
    list.append(above, anchor);
    document.body.appendChild(list);
    boxes.set(list, box(0, 400));
    boxes.set(anchor, box(140));

    const session = openSession({ statusId: '1', mediaId: 'embed-1', kind: 'iframe', url: PLAYER });
    registerAnchor({ key: session.key, element: anchor, prefer: true, releaseMode: () => 'detach' });
    const observer = FakeResizeObserver.instances[0];
    expect(observer.elements).toContain(list);
    expect(observer.elements).toContain(anchor);

    observer.callback();
    await flushLayout();
    expect(session.node.style.top).toBe('140px');

    boxes.set(anchor, box(340));
    boxes.set(list, box(0, 600));
    observer.callback();
    await flushLayout();

    expect(session.node.style.top).toBe('340px');
    expect(session.node.getAttribute('src')).toBe(PLAYER);
    expect(session.node.parentElement.id).toBe('external-player-host');
    list.remove();
  });

  it('follows the fixed slot when its position changes without a scroll event', async () => {
    const dock = document.createElement('div');
    dock.className = 'external-player-dock';
    const slot = document.createElement('div');
    slot.className = 'external-player-dock__slot';
    dock.appendChild(slot);
    document.body.appendChild(dock);
    const anchor = document.createElement('div');
    document.body.appendChild(anchor);
    boxes.set(anchor, box(40));
    boxes.set(slot, box(500, 180));

    const session = openSession({ statusId: '2', mediaId: 'embed-1', kind: 'iframe', url: PLAYER });
    registerAnchor({ key: session.key, element: anchor, prefer: true, releaseMode: () => 'detach' });
    registerDockSlot(slot);
    pinSession(session.key);
    const observer = FakeResizeObserver.instances[0];
    expect(observer.elements).toContain(slot);
    expect(observer.elements).toContain(dock);

    observer.callback();
    await flushLayout();
    expect(session.node.style.top).toBe('500px');

    boxes.set(slot, box(620, 180));
    observer.callback();
    await flushLayout();

    expect(session.node.style.top).toBe('620px');
    expect(session.node).toBe(openSession({ statusId: '2', mediaId: 'embed-1', kind: 'iframe', url: PLAYER }).node);
    dock.remove();
    anchor.remove();
  });
});
