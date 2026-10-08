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

export function syncUserPostingContextTargetPanels(form) {
  const kindField = form.querySelector('[data-target-kind]');

  if (!kindField) {
    return;
  }

  form.querySelectorAll('[data-target-panel]').forEach((panel) => {
    panel.hidden = panel.getAttribute('data-target-panel') !== kindField.value;
  });
}

export function applyUserPostingContextPreview(root, payload) {
  const preview = root.querySelector('[data-user-posting-context-preview]');
  const constraints = root.querySelector('[data-user-posting-context-constraints]');
  const preserved = snapshotFields(root);

  if (preview && typeof payload.preview_html === 'string') {
    preview.innerHTML = payload.preview_html;
  }

  if (constraints && typeof payload.constraint_html === 'string') {
    constraints.innerHTML = payload.constraint_html;
  }

  restoreFields(preserved);

  return { preservedCount: preserved.length };
}

export function bindUserPostingContextPreview(root = document, options = {}) {
  const form = root.querySelector('[data-user-posting-context-form]');

  if (!form || form.dataset.previewBound === 'true') {
    return;
  }

  form.dataset.previewBound = 'true';
  syncUserPostingContextTargetPanels(form);

  const fetchImpl = options.fetchImpl || window.fetch.bind(window);
  const delay = options.delay === undefined || options.delay === null ? 250 : options.delay;
  let timer = null;

  const refresh = () => {
    if (!form.dataset.previewUrl) {
      return;
    }

    const body = new FormData(form);

    if (form.dataset.recordId) {
      body.set('id', form.dataset.recordId);
    }

    const token = document.querySelector('meta[name="csrf-token"]');

    fetchImpl(form.dataset.previewUrl, {
      method: 'POST',
      credentials: 'same-origin',
      headers: {
        Accept: 'application/json',
        'X-Requested-With': 'XMLHttpRequest',
        'X-CSRF-Token': token ? token.getAttribute('content') : '',
      },
      body,
    }).then((response) => (response && response.ok ? response.json() : null)).then((payload) => {
      if (!payload) {
        return null;
      }

      applyUserPostingContextPreview(root, payload);

      if (typeof options.renderEmoji === 'function') {
        options.renderEmoji(root);
      }

      return null;
    }).catch(() => {});
  };

  const schedule = () => {
    window.clearTimeout(timer);
    timer = window.setTimeout(refresh, delay);
  };

  form.addEventListener('input', schedule);
  form.addEventListener('change', (event) => {
    if (event.target && event.target.matches('[data-target-kind]')) {
      syncUserPostingContextTargetPanels(form);
    }

    schedule();
  });
}
