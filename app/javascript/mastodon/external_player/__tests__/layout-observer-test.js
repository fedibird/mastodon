import { act } from '@testing-library/react';

class FakeResizeObserver {

  constructor (callback) {
    this.callback = callback;
    this.elements = [];
    this.unobserveCount = 0;
    this.disconnectCount = 0;
    FakeResizeObserver.instances.push(this);
  }

  observe (element) {
    if (!this.elements.includes(element)) {
      this.elements.push(element);
    }
  }

  unobserve (element) {
    this.unobserveCount += 1;
    this.elements = this.elements.filter(item => item !== element);
  }

  disconnect () {
    this.disconnectCount += 1;
    this.elements = [];
  }

}

FakeResizeObserver.instances = [];
global.ResizeObserver = FakeResizeObserver;

const {
  closeSession,
  connectedPlayerNodes,
  openSession,
  pinSession,
  registerAnchor,
  registerDockSlot,
  resetExternalPlayersForTests,
  unregisterAnchor,
  updateAnchorElement,
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

  it('drops detached layout targets while one pinned iframe stays', async () => {
    const nativeMutation = global.MutationObserver;
    const mutationRecords = [];

    class RecordingMutation {

      constructor (callback) {
        this.callback = callback;
        this.elements = new Set();
        this.disconnectCount = 0;
        mutationRecords.push(this);
      }

      observe (element) {
        this.elements.add(element);
      }

      disconnect () {
        this.disconnectCount += 1;
        this.elements.clear();
      }

    }

    global.MutationObserver = RecordingMutation;

    const scrollport = document.createElement('div');
    scrollport.style.overflow = 'auto';
    const pinnedAnchor = document.createElement('div');
    scrollport.appendChild(pinnedAnchor);
    document.body.appendChild(scrollport);
    boxes.set(scrollport, box(0, 400));
    boxes.set(pinnedAnchor, box(140));

    const pinned = openSession({ statusId: 'pinned', mediaId: 'embed', kind: 'iframe', url: PLAYER });
    const pinnedNode = pinned.node;
    const pinnedId = registerAnchor({ key: pinned.key, element: pinnedAnchor, prefer: true, releaseMode: () => 'detach' });
    pinSession(pinned.key);

    const dock = document.createElement('div');
    const slot = document.createElement('div');
    dock.appendChild(slot);
    document.body.appendChild(dock);
    boxes.set(slot, box(500, 180));
    const releaseDock = registerDockSlot(slot);

    for (let index = 0; index < 5; index += 1) {
      const port = document.createElement('div');
      port.style.overflow = 'auto';
      const anchor = document.createElement('div');
      port.appendChild(anchor);
      document.body.appendChild(port);
      const session = openSession({ statusId: `other-${index}`, mediaId: 'embed', kind: 'iframe', url: PLAYER });
      const anchorId = registerAnchor({ key: session.key, element: anchor, prefer: true, releaseMode: () => 'detach' });
      unregisterAnchor(anchorId);
      port.remove();
      await act(async () => {});
    }

    const resize = FakeResizeObserver.instances[FakeResizeObserver.instances.length - 1];
    const mutation = mutationRecords[mutationRecords.length - 1];
    const detached = (elements) => elements.filter(element => !element.isConnected);

    expect(connectedPlayerNodes('iframe')).toHaveLength(1);
    expect(pinnedNode.isConnected).toBe(true);
    expect(pinnedNode.getAttribute('src')).toBe(PLAYER);
    expect(resize.unobserveCount).toBeGreaterThan(0);
    expect(resize.disconnectCount).toBe(0);
    expect(detached(resize.elements)).toEqual([]);
    expect(resize.elements).toContain(scrollport);
    expect(resize.elements).toContain(pinnedAnchor);
    expect(detached(Array.from(mutation.elements))).toEqual([]);
    expect(mutation.elements.has(scrollport)).toBe(true);

    const replacement = document.createElement('div');
    scrollport.appendChild(replacement);
    boxes.set(replacement, box(180));
    updateAnchorElement(pinnedId, replacement);
    expect(resize.elements).not.toContain(pinnedAnchor);
    expect(resize.elements).toContain(replacement);
    expect(resize.elements).toContain(scrollport);
    expect(openSession({ statusId: 'pinned', mediaId: 'embed', kind: 'iframe', url: PLAYER }).node).toBe(pinnedNode);

    boxes.set(slot, box(640, 180));
    resize.callback();
    await flushLayout();
    expect(pinnedNode.style.top).toBe('640px');

    releaseDock();
    expect(resize.elements).not.toContain(slot);
    expect(resize.elements).toContain(scrollport);
    expect(pinnedNode.isConnected).toBe(true);

    closeSession(pinned.key);
    await act(async () => {});
    expect(connectedPlayerNodes('iframe')).toHaveLength(0);
    expect(resize.disconnectCount).toBeGreaterThan(0);

    global.MutationObserver = nativeMutation;
    scrollport.remove();
    dock.remove();
  });
});
