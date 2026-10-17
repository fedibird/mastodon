// Reusable timeline-anchor fixtures for later history resume and column search.
// Geometry is explicit: scrollTop changes move the rows, ids stay strings.

const rect = (top, height, width = 320) => ({
  top,
  bottom: top + height,
  left: 0,
  right: width,
  width,
  height,
  x: 0,
  y: top,
  toJSON () {},
});

export const SNOWFLAKE_OVER_53_BITS = '12634567890123456789';
export const BOOST_WRAPPER_ID = '2000000000000000001';
export const BOOST_ORIGINAL_ID = '1999999999999999999';

export const mountStickyHeader = (top, bottom) => {
  const portal = document.createElement('div');
  portal.id = 'tabs-bar__portal';
  const wrapper = document.createElement('div');
  wrapper.className = 'tabs-bar__wrapper';
  wrapper.getBoundingClientRect = () => rect(top, Math.max(0, bottom - top));
  wrapper.appendChild(portal);
  document.body.appendChild(wrapper);

  return wrapper;
};

const rowHeight = (row) => (typeof row.height === 'function' ? row.height() : row.height);

const layoutRows = (list, scroller, rows, { origin }) => {
  rows.forEach((row, index) => {
    const node = document.createElement(row.gap ? 'div' : 'article');

    if (row.gap) {
      node.className = 'load-gap';
    } else {
      node.setAttribute('data-id', row.statusId);

      if (row.innerStatusId) {
        const inner = document.createElement('div');
        inner.className = 'status';
        inner.setAttribute('data-id', row.innerStatusId);
        node.appendChild(inner);
      }
    }

    node.getBoundingClientRect = () => {
      const offset = rows.slice(0, index).reduce((sum, item) => sum + rowHeight(item), 0);
      const height = rowHeight(row);

      return rect(origin + offset - scroller.scrollTop, height);
    };
    list.appendChild(node);
  });
};

// kind: 'document' scrolls the document. 'pane' | 'live' | 'history' scroll the list.
export const createTimelineHost = ({
  kind = 'pane',
  rows = [],
  scrollTop = 0,
  origin = 0,
  viewport = 640,
  width = 320,
} = {}) => {
  const list = document.createElement('div');
  list.className = 'scrollable';
  list.setAttribute('data-host-kind', kind);
  const scroller = kind === 'document' ? (document.scrollingElement || document.body) : list;

  scroller.scrollTop = scrollTop;
  layoutRows(list, scroller, rows, { origin });
  list.getBoundingClientRect = () => rect(kind === 'document' ? origin - scroller.scrollTop : origin, viewport, width);

  if (kind !== 'document') {
    document.body.appendChild(list);
  } else if (!list.isConnected) {
    document.body.appendChild(list);
  }

  return {
    kind,
    list,
    scroller,
    scrollHost: { kind, list, scroller },
    visibleTop: kind === 'document' ? 0 : origin,
  };
};

export const rowTop = (host, statusId) => {
  const row = host.list.querySelector(`article[data-id="${statusId}"]`);

  return row ? row.getBoundingClientRect().top : null;
};
