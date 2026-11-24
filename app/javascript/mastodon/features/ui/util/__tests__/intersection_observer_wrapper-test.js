import IntersectionObserverWrapper from '../intersection_observer_wrapper';

const accountId = '112807565960881667';

const article = (id) => {
  const node = document.createElement('article');

  node.setAttribute('data-id', id);
  return node;
};

describe('IntersectionObserverWrapper', () => {
  let observers;

  beforeEach(() => {
    observers = [];
    global.IntersectionObserver = jest.fn().mockImplementation((callback, options) => {
      const observer = {
        callback,
        options,
        observe: jest.fn(),
        unobserve: jest.fn(),
        disconnect: jest.fn(),
      };

      observers.push(observer);
      return observer;
    });
  });

  const connectPair = () => {
    const wrapper = new IntersectionObserverWrapper();
    const first = article(accountId);
    const second = article(accountId);
    const firstCallback = jest.fn();
    const secondCallback = jest.fn();

    wrapper.observe(accountId, first, firstCallback);
    wrapper.observe(accountId, second, secondCallback);
    wrapper.connect({ rootMargin: '300% 0px' });

    return { wrapper, first, second, firstCallback, secondCallback };
  };

  it('delivers each entry to its own node when two rows share an id', () => {
    const { first, second, firstCallback, secondCallback } = connectPair();
    const hidden = { target: first, isIntersecting: false };
    const shown = { target: second, isIntersecting: true };

    observers[0].callback([hidden, shown]);

    expect(firstCallback).toHaveBeenCalledTimes(1);
    expect(firstCallback).toHaveBeenCalledWith(hidden);
    expect(secondCallback).toHaveBeenCalledTimes(1);
    expect(secondCallback).toHaveBeenCalledWith(shown);
    expect(first.getAttribute('data-id')).toBe(accountId);
    expect(second.getAttribute('data-id')).toBe(accountId);
  });

  it('keeps a single-id timeline row on its own callback', () => {
    const wrapper = new IntersectionObserverWrapper();
    const node = article('status-1');
    const callback = jest.fn();
    const entry = { target: node, isIntersecting: true };

    wrapper.observe('status-1', node, callback);
    wrapper.connect({});
    observers[0].callback([entry]);

    expect(callback).toHaveBeenCalledTimes(1);
    expect(callback).toHaveBeenCalledWith(entry);
    expect(observers[0].observe).toHaveBeenCalledTimes(1);
    expect(observers[0].observe).toHaveBeenCalledWith(node);
  });

  it('reobserves every node with a shared id after reconnect', () => {
    const { wrapper, first, second, firstCallback, secondCallback } = connectPair();

    wrapper.connect({ root: null });

    expect(observers).toHaveLength(2);
    expect(observers[0].disconnect).toHaveBeenCalledTimes(1);
    expect(observers[1].observe).toHaveBeenCalledWith(first);
    expect(observers[1].observe).toHaveBeenCalledWith(second);
    expect(wrapper.registrations.size).toBe(2);

    const entry = { target: first, isIntersecting: true };

    observers[1].callback([entry]);
    expect(firstCallback).toHaveBeenCalledWith(entry);
    expect(secondCallback).not.toHaveBeenCalled();
  });

  it('keeps the other node when one shared-id row is unobserved', () => {
    const { wrapper, first, second, firstCallback, secondCallback } = connectPair();

    wrapper.unobserve(accountId, first);

    expect(observers[0].unobserve).toHaveBeenCalledTimes(1);
    expect(observers[0].unobserve).toHaveBeenCalledWith(first);
    expect(wrapper.registrations.has(first)).toBe(false);
    expect(wrapper.registrations.get(second).callback).toBe(secondCallback);

    const shown = { target: second, isIntersecting: true };
    const stale = { target: first, isIntersecting: false };

    observers[0].callback([stale, shown]);
    expect(firstCallback).not.toHaveBeenCalled();
    expect(secondCallback).toHaveBeenCalledTimes(1);
    expect(secondCallback).toHaveBeenCalledWith(shown);

    wrapper.connect({ root: document.body });
    expect(observers[1].observe).toHaveBeenCalledTimes(1);
    expect(observers[1].observe).toHaveBeenCalledWith(second);
  });

  it('observes a node that mounts after connect without dropping earlier rows', () => {
    const wrapper = new IntersectionObserverWrapper();
    const first = article(accountId);
    const second = article(accountId);
    const firstCallback = jest.fn();
    const secondCallback = jest.fn();

    wrapper.connect({});
    wrapper.observe(accountId, first, firstCallback);
    wrapper.observe(accountId, second, secondCallback);

    expect(observers[0].observe).toHaveBeenNthCalledWith(1, first);
    expect(observers[0].observe).toHaveBeenNthCalledWith(2, second);

    observers[0].callback([
      { target: first, isIntersecting: false },
      { target: second, isIntersecting: true },
    ]);
    expect(firstCallback).toHaveBeenCalledTimes(1);
    expect(secondCallback).toHaveBeenCalledTimes(1);
  });

  it('replaces the callback when the same node is observed again', () => {
    const wrapper = new IntersectionObserverWrapper();
    const node = article('status-9');
    const firstCallback = jest.fn();
    const secondCallback = jest.fn();
    const entry = { target: node, isIntersecting: true };

    wrapper.observe('status-9', node, firstCallback);
    wrapper.connect({});
    wrapper.observe('status-9', node, secondCallback);
    observers[0].callback([entry]);

    expect(firstCallback).not.toHaveBeenCalled();
    expect(secondCallback).toHaveBeenCalledWith(entry);
    expect(wrapper.registrations.size).toBe(1);
  });

  it('ignores an entry whose target is not registered', () => {
    const { firstCallback, secondCallback } = connectPair();
    const stranger = article(accountId);

    expect(() => {
      observers[0].callback([{ target: stranger, isIntersecting: true }]);
    }).not.toThrow();
    expect(firstCallback).not.toHaveBeenCalled();
    expect(secondCallback).not.toHaveBeenCalled();
  });
});
