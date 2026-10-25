// Progressive enhancement for the Rails-rendered destination picker
// (settings/external_services/feed_routes/_picker). Without this script the
// form stays inside a <details> and saves normally. With it the same form
// moves into a modal <dialog> and can create a list in place. Saving
// destinations is always the normal form submit; list creation is separate.

const PICKER = '[data-feed-route-picker]';

const dialogSupported = () => (
  typeof window.HTMLDialogElement === 'function'
  && typeof window.HTMLDialogElement.prototype.showModal === 'function'
);

const csrfToken = () => {
  const meta = document.querySelector('meta[name="csrf-token"]');
  return meta ? meta.getAttribute('content') : '';
};

const firstFocusable = (form) => (
  form.querySelector('input[type="checkbox"]') || form.querySelector('button:not([hidden]), input[type="text"]')
);

const FOCUSABLE = 'a[href], button, input, select, textarea, [tabindex]:not([tabindex="-1"])';

const focusableWithin = (root) => (
  Array.from(root.querySelectorAll(FOCUSABLE)).filter((element) => (
    !element.disabled && !element.hidden && element.type !== 'hidden' && !element.closest('[hidden]')
  ))
);

// A native modal dialog still lets Tab reach the browser chrome, so wrap the
// focus at both ends.
const trapFocus = (dialog, event) => {
  if (event.key !== 'Tab') return;

  const items = focusableWithin(dialog);
  if (items.length === 0) return;

  const first = items[0];
  const last = items[items.length - 1];
  const active = document.activeElement;

  if (event.shiftKey && (active === first || !dialog.contains(active))) {
    event.preventDefault();
    last.focus();
  } else if (!event.shiftKey && (active === last || !dialog.contains(active))) {
    event.preventDefault();
    first.focus();
  }
};

const appendListChoice = (container, list, checked) => {
  if (container.querySelector(`input[value="${list.id}"]`)) {
    const existing = container.querySelector(`input[value="${list.id}"]`);
    if (checked) existing.checked = true;
    return existing;
  }

  const prefix = container.getAttribute('data-id-prefix');
  const item = document.createElement('li');
  const label = document.createElement('label');
  const input = document.createElement('input');
  const text = document.createElement('span');

  input.type = 'checkbox';
  input.name = 'feed_route[list_ids][]';
  input.value = list.id;
  input.id = `${prefix}-list-${list.id}`;
  input.checked = checked;
  label.setAttribute('for', input.id);
  text.className = 'feed-route-picker__choice';
  text.textContent = list.title;
  label.appendChild(input);
  label.appendChild(text);
  item.appendChild(label);
  container.appendChild(item);

  return input;
};

const enhanceCreate = (form) => {
  const create = form.querySelector('[data-feed-route-create]');
  if (!create) {
    return { cancelCreate: () => {}, isOpen: () => false, reset: () => {}, isBusy: () => false };
  }

  const toggle = create.querySelector('[data-feed-route-create-toggle]');
  const fields = create.querySelector('.feed-route-picker__create-fields');
  const input = create.querySelector('[data-feed-route-create-input]');
  const submit = create.querySelector('[data-feed-route-create-submit]');
  const save = form.querySelector('button[type="submit"]');
  const cancel = create.querySelector('[data-feed-route-create-cancel]');
  const status = create.querySelector('[data-feed-route-status]');
  let busy = false;
  let generation = 0;

  const setStatus = (message, state) => {
    status.textContent = message || '';
    status.setAttribute('data-state', state || '');
  };

  const isOpen = () => !fields.hidden;

  const collapse = (restoreFocus) => {
    fields.hidden = true;
    toggle.hidden = false;
    toggle.setAttribute('aria-expanded', 'false');
    input.value = '';
    if (restoreFocus) toggle.focus();
  };

  const expand = () => {
    fields.hidden = false;
    toggle.hidden = true;
    toggle.setAttribute('aria-expanded', 'true');
    setStatus('', '');
    input.focus();
  };

  const setBusy = (value) => {
    busy = value;
    submit.disabled = value;
    input.readOnly = value;
    if (save) save.disabled = value;
    create.setAttribute('aria-busy', value ? 'true' : 'false');
  };

  // A response that arrives after the dialog was closed or the creation was
  // cancelled still names a real list, so it is offered everywhere, but it is
  // never selected in a form the user already left.
  const addToPickers = (list, select) => {
    document.querySelectorAll(`${PICKER} [data-feed-route-lists]`).forEach((container) => {
      const own = select && form.contains(container);
      const added = appendListChoice(container, list, own);
      if (own) added.focus();
    });
  };

  const invalidate = () => {
    generation += 1;
    setBusy(false);
  };

  const cancelCreate = (restoreFocus) => {
    invalidate();
    collapse(restoreFocus);
  };

  const perform = async () => {
    if (busy) return;
    const token = generation;
    setBusy(true);
    setStatus('', '');

    try {
      const response = await fetch(create.getAttribute('data-url'), {
        method: 'POST',
        credentials: 'same-origin',
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
          'X-CSRF-Token': csrfToken(),
          'X-Requested-With': 'XMLHttpRequest',
        },
        body: JSON.stringify({ list: { title: input.value } }),
      });
      const body = await response.json().catch(() => ({}));
      const current = token === generation;

      if (response.ok && body.id) {
        addToPickers(body, current);
        if (current) {
          collapse(false);
          setStatus(body.message, 'success');
        }
      } else if (current) {
        setStatus(body.error || create.getAttribute('data-failure'), 'error');
        input.focus();
      }
    } catch (error) {
      if (token === generation) {
        setStatus(create.getAttribute('data-failure'), 'error');
        input.focus();
      }
    } finally {
      if (token === generation) setBusy(false);
    }
  };

  create.hidden = false;
  toggle.addEventListener('click', expand);
  cancel.addEventListener('click', () => cancelCreate(true));
  submit.addEventListener('click', perform);
  input.addEventListener('keydown', (event) => {
    if (event.key === 'Enter') {
      event.preventDefault();
      perform();
    } else if (event.key === 'Escape') {
      event.preventDefault();
      event.stopPropagation();
      cancelCreate(true);
    }
  });
  form.addEventListener('submit', (event) => {
    if (busy) event.preventDefault();
  });

  return {
    cancelCreate,
    isOpen,
    isBusy: () => busy,
    reset: () => {
      cancelCreate(false);
      setStatus('', '');
    },
  };
};

const enhancePicker = (picker) => {
  if (picker.hasAttribute('data-feed-route-enhanced')) return;
  picker.setAttribute('data-feed-route-enhanced', 'true');

  const fallback = picker.querySelector('details.feed-route-picker__fallback');
  const form = picker.querySelector('[data-feed-route-form]');
  if (!fallback || !form) return;

  const create = enhanceCreate(form);
  if (!dialogSupported()) return;

  const summary = fallback.querySelector('summary');
  const dialog = document.createElement('dialog');
  const opener = document.createElement('button');

  dialog.className = 'feed-route-picker__dialog';
  dialog.setAttribute('aria-labelledby', form.getAttribute('aria-labelledby') || '');
  dialog.setAttribute('aria-describedby', form.getAttribute('aria-describedby') || '');
  form.removeAttribute('aria-labelledby');
  form.removeAttribute('aria-describedby');
  form.querySelectorAll('[data-feed-route-close]').forEach((button) => {
    button.hidden = false;
    button.addEventListener('click', () => dialog.close());
  });
  dialog.appendChild(form);

  opener.type = 'button';
  opener.className = summary.className;
  opener.textContent = summary.textContent.trim();
  opener.setAttribute('aria-haspopup', 'dialog');
  ['aria-label', 'aria-describedby'].forEach((name) => {
    if (summary.hasAttribute(name)) opener.setAttribute(name, summary.getAttribute(name));
  });
  opener.addEventListener('click', () => {
    dialog.showModal();
    const target = firstFocusable(form);
    if (target) target.focus();
  });

  dialog.addEventListener('keydown', (event) => trapFocus(dialog, event));
  dialog.addEventListener('click', (event) => {
    if (event.target === dialog) dialog.close();
  });
  dialog.addEventListener('cancel', (event) => {
    if (create.isOpen()) {
      event.preventDefault();
      create.cancelCreate(true);
    }
  });
  dialog.addEventListener('close', () => {
    form.reset();
    create.reset();
    opener.focus();
  });

  fallback.replaceWith(opener);
  picker.appendChild(dialog);
};

export function initializeFeedRoutePickers(root = document) {
  root.querySelectorAll(PICKER).forEach(enhancePicker);
}
