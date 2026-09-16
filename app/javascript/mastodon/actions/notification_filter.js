export const FILTERABLE_NOTIFICATION_TYPES = [
  'mention',
  'status',
  'scheduled_status',
  'status_reference',
];

const isHideAction = filter => filter.filter_action === 'hide' || filter.filter_action === 1;

export function notificationFilterFlags(notification) {
  const filterResults = FILTERABLE_NOTIFICATION_TYPES.includes(notification.type)
    && notification.status
    && Array.isArray(notification.status.filtered)
    ? notification.status.filtered.filter(result => (
      result.filter
      && Array.isArray(result.filter.context)
      && result.filter.context.includes('notifications')
    ))
    : [];

  if (filterResults.some(result => isHideAction(result.filter))) {
    return { drop: true, filtered: false };
  }

  return { drop: false, filtered: filterResults.length > 0 };
}
