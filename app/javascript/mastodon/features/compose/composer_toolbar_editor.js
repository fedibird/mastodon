import {
  dumpComposerToolbar,
  moveComposerToolbarItem,
  normalizeComposerToolbar,
  targetIndexForPointer,
} from './composer_toolbar';

const parseLabels = root => {
  try {
    const labels = JSON.parse(root.dataset.labels || '');

    if (!labels || typeof labels !== 'object') {
      return null;
    }

    return labels;
  } catch (_error) {
    return null;
  }
};

const appendText = (parent, text) => {
  parent.appendChild(document.createTextNode(text));
};

const renderRow = (item, index, count, labels) => {
  const row = document.createElement('li');
  const name = (labels.items && labels.items[item.id]) || item.id;
  const icon = (labels.icons && labels.icons[item.id]) || 'circle';

  row.className = 'composer-toolbar__row';
  row.dataset.id = item.id;

  const handle = document.createElement('button');
  handle.type = 'button';
  handle.className = 'composer-toolbar__handle';
  handle.dataset.dragHandle = 'true';
  handle.setAttribute('aria-label', labels.drag || '');
  const grip = document.createElement('i');
  grip.className = 'fa fa-bars';
  grip.setAttribute('aria-hidden', 'true');
  handle.appendChild(grip);
  row.appendChild(handle);

  const title = document.createElement('span');
  title.className = 'composer-toolbar__name';
  const mark = document.createElement('i');
  mark.className = `fa fa-${icon}`;
  mark.setAttribute('aria-hidden', 'true');
  title.appendChild(mark);
  const label = document.createElement('span');
  appendText(label, name);
  title.appendChild(label);
  row.appendChild(title);

  const select = document.createElement('select');
  select.className = 'composer-toolbar__placement';
  select.dataset.placement = 'true';
  select.setAttribute('aria-label', `${name} ${labels.placement || ''}`.trim());
  ['visible', 'menu', 'hidden'].forEach(placement => {
    const option = document.createElement('option');
    option.value = placement;
    appendText(option, (labels.placements && labels.placements[placement]) || placement);
    select.appendChild(option);
  });
  select.value = item.placement;
  row.appendChild(select);

  const moves = document.createElement('span');
  moves.className = 'composer-toolbar__moves';
  [['up', labels.moveUp, index === 0], ['down', labels.moveDown, index === count - 1]].forEach(([direction, text, disabled]) => {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'button composer-toolbar__move';
    button.dataset.move = direction;
    button.disabled = disabled;
    button.setAttribute('aria-label', `${text || direction} ${name}`);
    appendText(button, text || direction);
    moves.appendChild(button);
  });
  row.appendChild(moves);

  return row;
};

const nodeList = collection => {
  const result = [];

  for (let index = 0; index < collection.length; index += 1) {
    result.push(collection[index]);
  }

  return result;
};

const selectorEscape = value => {
  if (window.CSS && CSS.escape) {
    return CSS.escape(value);
  }

  return String(value).replace(/"/g, '\\"');
};

export const installComposerToolbarEditor = root => {
  if (!root || root.dataset.composerToolbarReady === 'true') {
    return () => {};
  }

  const labels = parseLabels(root);
  const list = root.querySelector('[data-composer-toolbar-list]');
  const field = root.querySelector('[data-composer-toolbar-field]');

  if (!labels || !list || !field) {
    return () => {};
  }

  root.dataset.composerToolbarReady = 'true';

  const initial = normalizeComposerToolbar(root.dataset.initial);
  const savedItems = () => normalizeComposerToolbar(root.dataset.saved || root.dataset.initial);
  let items = initial.map(item => ({ ...item }));
  let drag = null;

  const savedValue = () => dumpComposerToolbar(savedItems());

  const sync = () => {
    field.value = dumpComposerToolbar(items);
    root.dataset.dirty = field.value === savedValue() ? 'false' : 'true';
  };

  const paint = () => {
    const fragment = document.createDocumentFragment();

    items.forEach((item, index) => {
      const row = renderRow(item, index, items.length, labels);

      if (drag && drag.id === item.id) {
        row.classList.add('is-dragging');
      }

      fragment.appendChild(row);
    });

    while (list.firstChild) {
      list.removeChild(list.firstChild);
    }

    list.appendChild(fragment);
    sync();
  };

  const moveTo = (id, toIndex, focusSelector) => {
    const next = moveComposerToolbarItem(items, id, toIndex);

    if (next === items) {
      return;
    }

    items = next;
    paint();

    if (!focusSelector) {
      return;
    }

    const focus = list.querySelector(`[data-id="${selectorEscape(id)}"] ${focusSelector}`);

    if (focus && typeof focus.focus === 'function') {
      focus.focus();
    }
  };

  const onChange = event => {
    const select = event.target.closest('[data-placement]');

    if (!select || !list.contains(select)) {
      return;
    }

    const id = select.closest('[data-id]').dataset.id;
    const placement = select.value;

    if (!['visible', 'menu', 'hidden'].includes(placement)) {
      return;
    }

    items = items.map(item => (item.id === id ? { ...item, placement } : item));
    sync();
  };

  const onClick = event => {
    const button = event.target.closest('[data-move]');

    if (!button || !list.contains(button)) {
      return;
    }

    event.preventDefault();
    const row = button.closest('[data-id]');
    const index = items.findIndex(item => item.id === row.dataset.id);
    const delta = button.dataset.move === 'up' ? -1 : 1;
    moveTo(row.dataset.id, index + delta, `[data-move="${button.dataset.move}"]`);
  };

  const onKeyDown = event => {
    const handle = event.target.closest('[data-drag-handle]');

    if (!handle || !list.contains(handle) || (event.key !== 'ArrowUp' && event.key !== 'ArrowDown')) {
      return;
    }

    event.preventDefault();
    const row = handle.closest('[data-id]');
    const index = items.findIndex(item => item.id === row.dataset.id);
    moveTo(row.dataset.id, index + (event.key === 'ArrowUp' ? -1 : 1), '[data-drag-handle]');
  };

  const rowRects = () => nodeList(list.querySelectorAll('[data-id]')).map(row => {
    const rect = row.getBoundingClientRect();

    return { top: rect.top, height: rect.height || 1 };
  });

  const onPointerMove = event => {
    if (!drag || event.pointerId !== drag.pointerId) {
      return;
    }

    const rows = nodeList(list.querySelectorAll('[data-id]'));
    const dragIndex = rows.findIndex(row => row.dataset.id === drag.id);
    const next = targetIndexForPointer(rowRects(), dragIndex, event.clientY);

    if (next === dragIndex) {
      return;
    }

    moveTo(drag.id, next);
  };

  const finishDrag = event => {
    if (!drag || (event && event.pointerId !== drag.pointerId)) {
      return;
    }

    drag = null;
    paint();
    document.removeEventListener('pointermove', onPointerMove);
    document.removeEventListener('pointerup', finishDrag);
    document.removeEventListener('pointercancel', finishDrag);
  };

  const onPointerDown = event => {
    const handle = event.target.closest('[data-drag-handle]');

    if (!handle || !list.contains(handle)) {
      return;
    }

    if (event.pointerType === 'mouse' && event.button !== 0) {
      return;
    }

    event.preventDefault();
    const row = handle.closest('[data-id]');
    drag = { id: row.dataset.id, pointerId: event.pointerId };
    row.classList.add('is-dragging');

    if (handle.setPointerCapture) {
      try {
        handle.setPointerCapture(event.pointerId);
      } catch (_error) {
        // jsdom and some browsers reject capture; document listeners still track the pointer.
      }
    }

    document.addEventListener('pointermove', onPointerMove);
    document.addEventListener('pointerup', finishDrag);
    document.addEventListener('pointercancel', finishDrag);
  };

  const onCancel = event => {
    event.preventDefault();
    drag = null;
    items = savedItems().map(item => ({ ...item }));
    paint();
  };

  const onBeforeUnload = event => {
    if (!root.isConnected || root.dataset.submitting === 'true' || root.dataset.dirty !== 'true') {
      return;
    }

    event.preventDefault();
    event.returnValue = '';
  };

  const onPageShow = event => {
    if (event.persisted) {
      root.dataset.submitting = 'false';
    }
  };

  const form = root.closest('form');
  const onSubmit = () => {
    root.dataset.submitting = 'true';
  };

  list.addEventListener('change', onChange);
  list.addEventListener('click', onClick);
  list.addEventListener('keydown', onKeyDown);
  list.addEventListener('pointerdown', onPointerDown);

  const cancel = root.querySelector('[data-composer-toolbar-cancel]');

  if (cancel) {
    cancel.addEventListener('click', onCancel);
  }

  if (form) {
    form.addEventListener('submit', onSubmit);
  }

  window.addEventListener('beforeunload', onBeforeUnload);
  window.addEventListener('pageshow', onPageShow);
  paint();

  return () => {
    finishDrag();
    list.removeEventListener('change', onChange);
    list.removeEventListener('click', onClick);
    list.removeEventListener('keydown', onKeyDown);
    list.removeEventListener('pointerdown', onPointerDown);
    if (cancel) {
      cancel.removeEventListener('click', onCancel);
    }
    if (form) {
      form.removeEventListener('submit', onSubmit);
    }
    window.removeEventListener('beforeunload', onBeforeUnload);
    window.removeEventListener('pageshow', onPageShow);
    delete root.dataset.composerToolbarReady;
  };
};

export const installComposerToolbarEditors = parent => {
  const scope = parent && parent.querySelectorAll ? parent : document;

  scope.querySelectorAll('[data-composer-toolbar-editor]').forEach(root => {
    installComposerToolbarEditor(root);
  });
};
