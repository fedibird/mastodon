const READY = 'externalServiceHelpReady';

function tokens(value) {
  return (value || '').split(/\s+/).filter(Boolean);
}

function writeDescribedBy(element, bodyId, open) {
  const next = tokens(element.getAttribute('aria-describedby')).filter((token) => token !== bodyId);

  if (open) {
    next.push(bodyId);
  }

  if (next.length === 0) {
    element.removeAttribute('aria-describedby');
  } else {
    element.setAttribute('aria-describedby', next.join(' '));
  }
}

function syncHelp(details) {
  const doc = details.ownerDocument;

  if (!details.isConnected || !doc || typeof doc.getElementById !== 'function') {
    return;
  }
  const body = details.querySelector('.external-service-help__body');
  const summary = details.querySelector('summary');
  const bodyId = body && body.id;

  if (summary) {
    if (details.open && bodyId) {
      summary.setAttribute('aria-describedby', bodyId);
    } else {
      summary.removeAttribute('aria-describedby');
    }
  }

  if (!bodyId) {
    return;
  }

  tokens(details.dataset.describedControls).forEach((id) => {
    const control = doc.getElementById(id);

    if (!control) {
      return;
    }

    writeDescribedBy(control, bodyId, details.open);
  });
}

export function initializeExternalServiceHelp(root = document) {
  root.querySelectorAll('.external-service-help').forEach((details) => {
    if (details.dataset[READY] === 'true') {
      return;
    }

    details.dataset[READY] = 'true';
    details.addEventListener('toggle', () => syncHelp(details));
    details.addEventListener('click', (event) => {
      if (event.target.closest('summary')) {
        event.stopPropagation();
      }
    });
    syncHelp(details);
  });
}
