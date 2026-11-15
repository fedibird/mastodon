export function reboostWaitMinutes (seconds) {
  const value = Number(seconds);

  if (!Number.isFinite(value) || value <= 0) {
    return 0;
  }

  return Math.max(1, Math.ceil(value / 60));
}

export function reboostMenuItems ({ intl, messages, status, onReboost, onUnreblog, busy }) {
  const minutes = reboostWaitMinutes(status.get('reboost_retry_after'));

  return [
    {
      text: minutes > 0 ? intl.formatMessage(messages.reboost_wait, { minutes }) : intl.formatMessage(messages.reboost),
      action: onReboost,
      disabled: Boolean(busy) || minutes > 0,
    },
    {
      text: intl.formatMessage(messages.cancel_reblog_private),
      action: onUnreblog,
    },
    {
      text: intl.formatMessage(messages.reboost_hint),
      disabled: true,
    },
  ];
}
