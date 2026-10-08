const snapshotFields = (root) => (
  Array.from(root.querySelectorAll('[data-preserve-on-preview]')).map((field) => ({
    field,
    value: field.value,
    checked: field.checked,
  }))
);

const restoreFields = (preserved) => {
  preserved.forEach(({ field, value, checked }) => {
    if (field.value !== value) {
      field.value = value;
    }

    if (field.checked !== checked) {
      field.checked = checked;
    }
  });
};

const conditionNodes = (root) => (
  [
    root.querySelector('[data-user-posting-context-preview]'),
    root.querySelector('[data-user-posting-context-constraints]'),
    root.querySelector('[data-user-posting-context-destination]'),
  ].filter(Boolean)
);

const setConditionStale = (root, stale) => {
  conditionNodes(root).forEach((node) => {
    node.classList.toggle('user-posting-context-conditions--stale', stale);
    if (stale) {
      node.setAttribute('aria-busy', 'true');
    } else {
      node.removeAttribute('aria-busy');
    }
  });
};

const setPreviewStatus = (root, state) => {
  root.querySelectorAll('[data-user-posting-context-preview-status]').forEach((status) => {
    const message = state === 'pending' ? status.getAttribute('data-pending-message') : '';
    const failed = state === 'failed' ? status.getAttribute('data-failed-message') : '';
    status.textContent = state === 'failed' ? (failed || '') : (message || '');
    status.dataset.state = state;
  });
};

export function syncUserPostingContextTargetPanels(form) {
  const kindField = form.querySelector('[data-target-kind]');

  if (!kindField) {
    return;
  }

  form.querySelectorAll('[data-target-panel]').forEach((panel) => {
    panel.hidden = panel.getAttribute('data-target-panel') !== kindField.value;
  });
}

export function syncUserPostingContextChoicePanels(form) {
  form.querySelectorAll('[data-choice-control]').forEach((control) => {
    const name = control.getAttribute('data-choice-control');
    const value = control.value;

    form.querySelectorAll(`[data-choice-panel="${name}"]`).forEach((panel) => {
      panel.hidden = panel.getAttribute('data-choice-when') !== value;
    });

    form.querySelectorAll(`[data-choice-note="${name}"]`).forEach((note) => {
      note.hidden = note.getAttribute('data-choice-note-for') !== value;
    });
  });
}

export function applyUserPostingContextPreview(root, payload) {
  const preview = root.querySelector('[data-user-posting-context-preview]');
  const constraints = root.querySelector('[data-user-posting-context-constraints]');
  const destination = root.querySelector('[data-user-posting-context-destination]');
  const preserved = snapshotFields(root);

  if (preview && typeof payload.preview_html === 'string') {
    preview.innerHTML = payload.preview_html;
  }

  if (constraints && typeof payload.constraint_html === 'string') {
    constraints.innerHTML = payload.constraint_html;
  }

  if (destination && typeof payload.destination_html === 'string') {
    destination.innerHTML = payload.destination_html;
  }

  restoreFields(preserved);

  return { preservedCount: preserved.length };
}

const clearPreviewConditions = (root) => {
  applyUserPostingContextPreview(root, {
    preview_html: '',
    constraint_html: '',
    destination_html: '',
  });
  setConditionStale(root, false);
};

export function bindUserPostingContextPreview(root = document, options = {}) {
  const form = root.querySelector('[data-user-posting-context-form]');

  if (!form || form.dataset.previewBound === 'true') {
    return;
  }

  form.dataset.previewBound = 'true';
  syncUserPostingContextTargetPanels(form);
  syncUserPostingContextChoicePanels(form);

  const fetchImpl = options.fetchImpl || window.fetch.bind(window);
  const delay = options.delay === undefined || options.delay === null ? 250 : options.delay;
  const Abort = typeof AbortController === 'function' ? AbortController : null;
  let timer = null;
  let generation = 0;
  let activeAbort = null;

  const affectsPreview = (target) => {
    if (!target || typeof target.name !== 'string') {
      return false;
    }

    return /user_posting_context\[(target_kind|target_account_id|target_hashtag|visibility_choice|visibility_value|language_choice|language_code|sensitive_choice|sensitive_value|spoiler_choice|spoiler_text|hashtags_text)\]/.test(target.name);
  };

  const invalidate = () => {
    generation += 1;

    if (activeAbort) {
      activeAbort.abort();
      activeAbort = null;
    }

    setPreviewStatus(root, 'pending');
    setConditionStale(root, true);
  };

  const refresh = () => {
    if (!form.dataset.previewUrl) {
      return;
    }

    const requestId = generation;

    activeAbort = Abort ? new Abort() : null;

    const body = new FormData(form);

    if (form.dataset.recordId) {
      body.set('id', form.dataset.recordId);
    }

    const token = document.querySelector('meta[name="csrf-token"]');
    const request = {
      method: 'POST',
      credentials: 'same-origin',
      headers: {
        Accept: 'application/json',
        'X-Requested-With': 'XMLHttpRequest',
        'X-CSRF-Token': token ? token.getAttribute('content') : '',
      },
      body,
    };

    if (activeAbort) {
      request.signal = activeAbort.signal;
    }

    fetchImpl(form.dataset.previewUrl, request).then((response) => {
      if (requestId !== generation) {
        return null;
      }

      if (!response || !response.ok) {
        clearPreviewConditions(root);
        setPreviewStatus(root, 'failed');
        return null;
      }

      return response.json();
    }).then((payload) => {
      if (requestId !== generation || !payload) {
        return null;
      }

      applyUserPostingContextPreview(root, payload);
      setConditionStale(root, false);
      setPreviewStatus(root, 'ready');

      if (typeof options.renderEmoji === 'function') {
        options.renderEmoji(root);
      }

      return null;
    }).catch((error) => {
      if (requestId !== generation) {
        return;
      }

      if (error && error.name === 'AbortError') {
        return;
      }

      clearPreviewConditions(root);
      setPreviewStatus(root, 'failed');
    });
  };

  const schedule = () => {
    invalidate();
    window.clearTimeout(timer);
    timer = window.setTimeout(refresh, delay);
  };

  form.addEventListener('input', (event) => {
    if (affectsPreview(event.target)) {
      schedule();
    }
  });
  form.addEventListener('change', (event) => {
    if (event.target && event.target.matches('[data-target-kind]')) {
      syncUserPostingContextTargetPanels(form);
    }

    if (event.target && event.target.matches('[data-choice-control]')) {
      syncUserPostingContextChoicePanels(form);
    }

    if (affectsPreview(event.target)) {
      schedule();
    }
  });
}

export function bindUserPostingContextCardMenus(root = document) {
  const menus = () => root.querySelectorAll('[data-user-posting-context-menu]');

  menus().forEach((menu) => {
    if (menu.dataset.menuBound === 'true') {
      return;
    }

    menu.dataset.menuBound = 'true';
    const summary = menu.querySelector('summary');

    menu.addEventListener('keydown', (event) => {
      if (event.key !== 'Escape' || !menu.open) {
        return;
      }

      event.preventDefault();
      menu.open = false;

      if (summary) {
        summary.focus();
      }
    });
  });

  const host = root === document ? document.documentElement : root;

  if (host.dataset.postingContextMenusBound === 'true') {
    return;
  }

  host.dataset.postingContextMenusBound = 'true';
  root.addEventListener('click', (event) => {
    menus().forEach((menu) => {
      if (!menu.open || menu.contains(event.target)) {
        return;
      }

      menu.open = false;
    });
  });
}
