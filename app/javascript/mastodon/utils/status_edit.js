export const editableStatus = status => {
  if (!status) {
    return null;
  }

  const reblog = status.get('reblog');

  if (reblog && typeof reblog.get === 'function') {
    return reblog;
  }

  return status;
};

export const isStatusExpired = (status, now) => {
  const expiresAt = status && status.get('expires_at');

  if (!expiresAt) {
    return false;
  }

  return new Date(expiresAt).getTime() < now;
};

export const canEditStatus = (status, { me, expired = false, disablePost = false, now = Date.now() } = {}) => {
  if (status && status.get('reblog')) {
    return false;
  }

  const target = editableStatus(status);

  if (!target || disablePost) {
    return false;
  }

  const account = target.get('account');

  if (!account || account.get('id') !== me) {
    return false;
  }

  if (String(account.get('acct') || '').includes('@')) {
    return false;
  }

  if (expired || isStatusExpired(target, now)) {
    return false;
  }

  return true;
};
