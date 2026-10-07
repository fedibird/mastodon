const eachNode = (nodes, visit) => {
  for (let index = 0; index < nodes.length; index += 1) {
    const result = visit(nodes[index]);

    if (result) {
      return result;
    }
  }

  return null;
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

const connectedColumn = (column) => {
  if (!column || !column.querySelector || column.isConnected === false) {
    return null;
  }

  return column;
};

export const columnNodeFromRef = (column) => {
  if (!column) {
    return null;
  }

  if (column.node && column.node.querySelector) {
    return column.node;
  }

  if (column.querySelector) {
    return column;
  }

  return null;
};

export const captureVisibleStatusAnchor = (column) => {
  const target = connectedColumn(column);

  if (!target) {
    return null;
  }

  const scroller = scrollingElement(target);
  const visibleTop = visibleTopFor(scroller);
  const article = eachNode(target.querySelectorAll('article[data-id]'), item => (
    item.getBoundingClientRect().bottom > visibleTop + 8 ? item : null
  ));

  if (!article) {
    return null;
  }

  return {
    column: target,
    id: article.getAttribute('data-id'),
    offset: article.getBoundingClientRect().top - visibleTop,
    useDocument: usesDocument(scroller),
  };
};

export const restoreVisibleStatusAnchor = (anchor) => {
  if (!anchor) {
    return;
  }

  const column = connectedColumn(anchor.column);
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
