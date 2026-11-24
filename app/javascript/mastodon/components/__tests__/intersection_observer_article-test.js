import { act, render } from '@testing-library/react';
import React from 'react';

import IntersectionObserverArticle, { heightToPreserve } from '../intersection_observer_article';
import IntersectionObserverWrapper from '../../features/ui/util/intersection_observer_wrapper';

const rect = (height) => ({
  x: 0,
  y: 0,
  top: 0,
  left: 0,
  right: 180,
  bottom: height,
  width: 180,
  height,
  toJSON () {},
});

describe('heightToPreserve', () => {
  it('keeps the masonry slot when it is taller than the article box', () => {
    expect(heightToPreserve(93.75, 101.75)).toBe(101.75);
  });

  it('keeps the article box when there is no taller slot', () => {
    expect(heightToPreserve(120, 0)).toBe(120);
    expect(heightToPreserve(120, 120)).toBe(120);
    expect(heightToPreserve(120, undefined)).toBe(120);
  });
});

describe('IntersectionObserverArticle masonry virtualization', () => {
  let idle;

  beforeEach(() => {
    idle = [];
    global.requestIdleCallback = (callback) => {
      idle.push(callback);
      return idle.length;
    };
    global.cancelIdleCallback = () => {};
    global.IntersectionObserver = class {

      observe () {}

      unobserve () {}

      disconnect () {}

    };
  });

  const flushIdle = () => {
    const batch = idle.splice(0);

    act(() => {
      batch.forEach(callback => callback({ didTimeout: false, timeRemaining: () => 50 }));
    });
  };

  const renderRow = (ref) => {
    const wrapper = new IntersectionObserverWrapper();
    const view = render(
      <div data-layout-key='card:1'>
        <IntersectionObserverArticle ref={ref} intersectionObserverWrapper={wrapper} id='1' index={0} listLength={1}>
          <div className='status__wrapper status__wrapper--compact'>card</div>
        </IntersectionObserverArticle>
      </div>,
    );
    const article = view.container.querySelector('article');
    const slot = view.container.querySelector('[data-layout-key]');

    article.getBoundingClientRect = () => rect(93.75);
    slot.getBoundingClientRect = () => rect(101.75);

    return { ...view, wrapper, article, slot };
  };

  const deliver = (wrapper, article, entry) => {
    act(() => {
      wrapper.registrations.get(article).callback({
        target: article,
        ...entry,
      });
    });
  };

  const leaveView = ({ wrapper, article }) => {
    deliver(wrapper, article, {
      isIntersecting: false,
      boundingClientRect: rect(93.75),
    });
    flushIdle();
  };

  it('freezes the masonry slot instead of the shorter article box', () => {
    const view = renderRow();

    leaveView(view);

    expect(view.article.style.height).toBe('101.75px');
    expect(view.article.style.overflow).toBe('hidden');
  });

  it('does not replace a preserved slot with the collapsed placeholder height', () => {
    const ref = React.createRef();
    const view = renderRow(ref);

    leaveView(view);
    view.article.getBoundingClientRect = () => rect(40);
    view.slot.getBoundingClientRect = () => rect(40);
    act(() => {
      ref.current.calculateHeight();
    });

    expect(view.article.style.height).toBe('101.75px');
  });

  it('keeps a normal timeline row on its own article height', () => {
    const wrapper = new IntersectionObserverWrapper();
    const view = render(
      <IntersectionObserverArticle intersectionObserverWrapper={wrapper} id='9' index={0} listLength={1}>
        <div>status</div>
      </IntersectionObserverArticle>,
    );
    const article = view.container.querySelector('article');

    article.getBoundingClientRect = () => rect(88);

    deliver(wrapper, article, {
      isIntersecting: false,
      boundingClientRect: rect(88),
    });
    flushIdle();

    expect(article.style.height).toBe('88px');
  });

  it('virtualizes each row on its own when two articles share an account id', () => {
    const wrapper = new IntersectionObserverWrapper();
    let onIntersection = null;

    global.IntersectionObserver = class {

      constructor (callback) {
        onIntersection = callback;
      }

      observe () {}

      unobserve () {}

      disconnect () {}

    };

    const accountId = '112807565960881667';
    const view = render(
      <div>
        <IntersectionObserverArticle key='reaction-a' intersectionObserverWrapper={wrapper} id={accountId} index={11} listLength={34}>
          <div>first account row</div>
        </IntersectionObserverArticle>
        <IntersectionObserverArticle key='reaction-b' intersectionObserverWrapper={wrapper} id={accountId} index={12} listLength={34}>
          <div>second account row</div>
        </IntersectionObserverArticle>
      </div>,
    );
    const articles = Array.from(view.container.querySelectorAll('article'));

    articles.forEach(node => {
      node.getBoundingClientRect = () => rect(57);
    });
    wrapper.connect({});

    expect(articles.map(article => article.getAttribute('data-id'))).toEqual([accountId, accountId]);
    expect(articles.map(article => article.getAttribute('aria-posinset'))).toEqual(['12', '13']);

    act(() => {
      onIntersection([
        { isIntersecting: false, target: articles[0], boundingClientRect: rect(57) },
        { isIntersecting: true, target: articles[1], boundingClientRect: rect(57) },
      ]);
    });
    flushIdle();

    expect(articles[0].style.opacity).toBe('0');
    expect(articles[0].style.height).toBe('57px');
    expect(articles[0].style.overflow).toBe('hidden');
    expect(articles[1].style.opacity).toBe('');
    expect(articles[1].textContent).toContain('second account row');

    act(() => {
      onIntersection([
        { isIntersecting: true, target: articles[0], boundingClientRect: rect(57) },
      ]);
    });
    flushIdle();

    expect(articles[0].style.opacity).toBe('');
    expect(articles[0].style.height).toBe('');
    expect(articles[0].textContent).toContain('first account row');
    expect(articles[1].style.opacity).toBe('');

    view.rerender(
      <div>
        <IntersectionObserverArticle key='reaction-b' intersectionObserverWrapper={wrapper} id={accountId} index={0} listLength={1}>
          <div>second account row</div>
        </IntersectionObserverArticle>
      </div>,
    );

    const remaining = view.container.querySelector('article');

    expect(wrapper.registrations.size).toBe(1);
    expect(wrapper.registrations.has(remaining)).toBe(true);

    remaining.getBoundingClientRect = () => rect(57);
    act(() => {
      onIntersection([
        { isIntersecting: false, target: remaining, boundingClientRect: rect(57) },
      ]);
    });
    flushIdle();

    expect(remaining.style.opacity).toBe('0');
    expect(remaining.style.height).toBe('57px');
  });
});
