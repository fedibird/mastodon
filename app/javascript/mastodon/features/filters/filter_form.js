const READY = 'filterFormReady';

function syncContextDescriptions(fieldset) {
  const details = fieldset.querySelector('.filter-contexts__disclosure');

  if (!details) {
    return;
  }

  const summary = details.querySelector('summary');

  if (summary) {
    const label = details.open ? summary.dataset.hideLabel : summary.dataset.showLabel;

    if (label) {
      summary.textContent = label;
    }
  }

  fieldset.querySelectorAll('.filter-contexts__item').forEach((item) => {
    const box = item.querySelector('input[type="checkbox"]');
    const description = item.querySelector('.filter-contexts__description');

    if (!box || !description || !description.id) {
      return;
    }

    if (details.open) {
      box.setAttribute('aria-describedby', description.id);
    } else {
      box.removeAttribute('aria-describedby');
    }
  });
}

function syncWholeWordHelp(section) {
  const details = section.querySelector('.filter-keywords__help');

  if (!details) {
    return;
  }

  const body = details.querySelector('.filter-keywords__help-body');

  section.querySelectorAll('input[type="checkbox"][name$="[whole_word]"]').forEach((box) => {
    if (details.open && body && body.id) {
      box.setAttribute('aria-describedby', body.id);
    } else {
      box.removeAttribute('aria-describedby');
    }
  });
}

export function initializeFilterForms(root = document) {
  root.querySelectorAll('.filter-contexts').forEach((fieldset) => {
    if (fieldset.dataset[READY] === 'true') {
      return;
    }

    fieldset.dataset[READY] = 'true';

    fieldset.addEventListener('click', (event) => {
      const button = event.target.closest('[data-filter-contexts-action]');

      if (!button || !fieldset.contains(button)) {
        return;
      }

      const checked = button.dataset.filterContextsAction === 'select-all';

      fieldset.querySelectorAll('input[type="checkbox"][name$="[context][]"]').forEach((box) => {
        box.checked = checked;
      });
    });

    const details = fieldset.querySelector('.filter-contexts__disclosure');

    if (details) {
      details.addEventListener('toggle', () => syncContextDescriptions(fieldset));
    }

    syncContextDescriptions(fieldset);
  });

  root.querySelectorAll('.filter-keywords').forEach((section) => {
    if (section.dataset[READY] === 'true') {
      return;
    }

    section.dataset[READY] = 'true';

    const details = section.querySelector('.filter-keywords__help');

    if (details) {
      details.addEventListener('toggle', () => syncWholeWordHelp(section));
    }

    section.addEventListener('cocoon:after-insert', () => syncWholeWordHelp(section));
    syncWholeWordHelp(section);
  });
}
