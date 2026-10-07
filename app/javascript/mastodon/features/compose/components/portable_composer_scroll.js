const eachNode = (nodes, visit) => {
  for (let index = 0; index < nodes.length; index += 1) {
    const result = visit(nodes[index]);

    if (result) {
      return result;
    }
  }

  return null;
};

const columnByLabel = (label) => {
  if (!label || typeof document === 'undefined') {
    return null;
  }

  return eachNode(document.querySelectorAll('.column'), node => (
    node.getAttribute && node.getAttribute('aria-label') === label ? node : null
  ));
};

const scrollingElement = (column) => {
  const inner = column.querySelector('.scrollable');

  if (inner && inner.scrollHeight > inner.clientHeight + 1) {
    return inner;
  }

  return document.scrollingElement || document.body;
};

const usesDocument = (scroller) => scroller === document.scrollingElement || scroller === document.body;

const visibleTopFor = (scroller) => (
  usesDocument(scroller) ? 0 : scroller.getBoundingClientRect().top
);

const articleById = (column, id) => (
  eachNode(column.querySelectorAll('article[data-id]'), item => (
    item.getAttribute('data-id') === id ? item : null
  ))
);

export const captureVisibleStatusAnchor = (label) => {
  const column = columnByLabel(label);

  if (!column) {
    return null;
  }

  const scroller = scrollingElement(column);
  const visibleTop = visibleTopFor(scroller);
  const article = eachNode(column.querySelectorAll('article[data-id]'), item => (
    item.getBoundingClientRect().bottom > visibleTop + 8 ? item : null
  ));

  if (!article) {
    return null;
  }

  return {
    label,
    id: article.getAttribute('data-id'),
    offset: article.getBoundingClientRect().top - visibleTop,
    useDocument: usesDocument(scroller),
  };
};

export const restoreVisibleStatusAnchor = (anchor) => {
  if (!anchor) {
    return;
  }

  const column = columnByLabel(anchor.label);
  const article = column && articleById(column, anchor.id);

  if (!column || !article) {
    return;
  }

  const scroller = anchor.useDocument ? (document.scrollingElement || document.body) : column.querySelector('.scrollable');

  if (!scroller) {
    return;
  }

  const delta = article.getBoundingClientRect().top - visibleTopFor(scroller) - anchor.offset;

  if (Math.abs(delta) > 1) {
    scroller.scrollTop += delta;
  }
};

export const scheduleStatusAnchorRestore = (anchor) => {
  if (!anchor) {
    return () => {};
  }

  let frame = requestAnimationFrame(() => {
    restoreVisibleStatusAnchor(anchor);
    frame = requestAnimationFrame(() => restoreVisibleStatusAnchor(anchor));
  });
  const timers = [60, 200].map(delay => setTimeout(() => restoreVisibleStatusAnchor(anchor), delay));

  return () => {
    cancelAnimationFrame(frame);
    timers.forEach(clearTimeout);
  };
};
