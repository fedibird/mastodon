export function reboostWaitMinutes (seconds) {
  const value = Number(seconds);

  if (!Number.isFinite(value) || value <= 0) {
    return 0;
  }

  return Math.max(1, Math.ceil(value / 60));
}

export function reboostRemainingSeconds (status, now = Date.now()) {
  const until = Number(status.get('reboost_retry_until'));

  if (Number.isFinite(until) && until > 0) {
    return Math.max(0, Math.ceil((until - now) / 1000));
  }

  const seconds = Number(status.get('reboost_retry_after'));

  if (!Number.isFinite(seconds) || seconds <= 0) {
    return 0;
  }

  return seconds;
}

export function armReboostClock (status, onFire) {
  const seconds = reboostRemainingSeconds(status);

  if (seconds <= 0) {
    return null;
  }

  return setTimeout(onFire, seconds * 1000);
}

export function reboostOperationId (status) {
  const operation = status.get('reboost_operation');

  if (!operation) {
    return null;
  }

  const id = operation.get ? operation.get('id') : operation.id;

  return id || null;
}

export function reboostMenuItems ({ intl, messages, status, onReboost, onUnreblog, onCheck, busy, pendingOnly }) {
  const operationId = reboostOperationId(status);

  if (pendingOnly) {
    const pendingItems = [];

    if (operationId && onCheck) {
      pendingItems.push({
        text: intl.formatMessage(messages.reboost_check),
        action: onCheck,
      });
    }

    pendingItems.push({
      text: intl.formatMessage(messages.cancel_reblog_private),
      action: onUnreblog,
    });

    return pendingItems;
  }

  const minutes = reboostWaitMinutes(reboostRemainingSeconds(status));
  const items = [
    {
      text: minutes > 0 ? intl.formatMessage(messages.reboost_wait, { minutes }) : intl.formatMessage(messages.reboost),
      action: onReboost,
      disabled: Boolean(busy) || minutes > 0,
    },
    {
      text: intl.formatMessage(messages.cancel_reblog_private),
      action: onUnreblog,
    },
  ];

  if (operationId && onCheck) {
    items.push({
      text: intl.formatMessage(messages.reboost_check),
      action: onCheck,
    });
  }

  items.push({
    text: intl.formatMessage(messages.reboost_hint),
    disabled: true,
  });

  return items;
}
