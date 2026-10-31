export const COMPOSER_TOOLBAR_IDS = [
  'posting_account',
  'media',
  'cw',
  'language',
  'datetime',
  'searchability',
  'poll',
];

export const COMPOSER_TOOLBAR_PLACEMENTS = ['visible', 'menu', 'hidden'];

const DEFAULT_PLACEMENT = {
  posting_account: 'visible',
  media: 'visible',
  cw: 'visible',
  language: 'visible',
  datetime: 'menu',
  searchability: 'menu',
  poll: 'menu',
};

export const DEFAULT_COMPOSER_TOOLBAR = COMPOSER_TOOLBAR_IDS.map(id => ({
  id,
  placement: DEFAULT_PLACEMENT[id],
}));

const remember = (found, order, id, placement) => {
  if (!COMPOSER_TOOLBAR_IDS.includes(id) || found.has(id)) {
    return;
  }

  found.set(id, COMPOSER_TOOLBAR_PLACEMENTS.includes(placement) ? placement : DEFAULT_PLACEMENT[id]);
  order.push(id);
};

const consumeList = (list, found, order) => {
  if (!Array.isArray(list)) {
    return;
  }

  list.forEach(entry => {
    if (!entry || typeof entry !== 'object') {
      return;
    }

    remember(found, order, entry.id, entry.placement);
  });
};

const consumeCanonical = (value, found, order) => {
  if (typeof value !== 'string' || !value.startsWith('v1|')) {
    return false;
  }

  value.slice(3).split('|').filter(Boolean).forEach(part => {
    const index = part.indexOf(':');

    if (index <= 0) {
      return;
    }

    remember(found, order, part.slice(0, index), part.slice(index + 1));
  });

  return true;
};

const consumeJson = (value, found, order) => {
  if (typeof value !== 'string' || (!value.startsWith('{') && !value.startsWith('['))) {
    return;
  }

  try {
    const parsed = JSON.parse(value);

    if (Array.isArray(parsed)) {
      consumeList(parsed, found, order);
    } else if (parsed && Array.isArray(parsed.items)) {
      consumeList(parsed.items, found, order);
    }
  } catch (_error) {
    // Unreadable JSON uses the defaults filled in below.
  }
};

// Saved values, partial documents, unknown ids, and bad placements become a
// complete list. The caller never has to guard a missing control.
export const normalizeComposerToolbar = value => {
  const found = new Map();
  const order = [];

  if (Array.isArray(value)) {
    consumeList(value, found, order);
  } else if (value && typeof value === 'object' && Array.isArray(value.items)) {
    consumeList(value.items, found, order);
  } else if (!consumeCanonical(value, found, order)) {
    consumeJson(value, found, order);
  }

  COMPOSER_TOOLBAR_IDS.forEach(id => {
    if (!found.has(id)) {
      found.set(id, DEFAULT_PLACEMENT[id]);
      order.push(id);
    }
  });

  return order.map(id => ({ id, placement: found.get(id) }));
};

export const dumpComposerToolbar = items => {
  const normalized = normalizeComposerToolbar(items);

  return `v1|${normalized.map(item => `${item.id}:${item.placement}`).join('|')}`;
};

export const moveComposerToolbarItem = (items, id, toIndex) => {
  const index = items.findIndex(item => item.id === id);

  if (index < 0 || toIndex === index || toIndex < 0 || toIndex >= items.length) {
    return items;
  }

  const copy = items.slice();
  const [row] = copy.splice(index, 1);
  copy.splice(toIndex, 0, row);

  return copy;
};

// Swap as soon as the pointer crosses another row's midpoint. The returned
// index is the row the dragged item should occupy before the pointer is released.
export const targetIndexForPointer = (rects, dragIndex, clientY) => {
  let next = dragIndex;

  rects.forEach((rect, index) => {
    if (!rect || index === dragIndex) {
      return;
    }

    const mid = rect.top + (rect.height / 2);

    if (index < dragIndex && clientY < mid) {
      next = Math.min(next, index);
    }

    if (index > dragIndex && clientY > mid) {
      next = Math.max(next, index);
    }
  });

  return next;
};

// A configured link is a delegated identity. The signed-in account alone is
// not a link. Failed catalog loads stay available so the existing retry path
// can still be opened by someone allowed to link accounts.
export const postingAccountControlAvailable = ({ catalog, status, selectedId, canLink }) => {
  const hasDelegated = Boolean(catalog && typeof catalog.some === 'function' && catalog.some(identity => identity && identity.get && identity.get('kind') === 'delegated'));

  if (hasDelegated) {
    return true;
  }

  if (!canLink) {
    return false;
  }

  if (typeof selectedId === 'string' && selectedId.startsWith('delegated:')) {
    return true;
  }

  return status === 'failed';
};
