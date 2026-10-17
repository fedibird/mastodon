// One settle per seek session. There is no frame budget: a slow paint must
// not be treated as not_loaded. cancel() resolves the waiter immediately so
// a later notify cannot restore after close or unmount.

export const createJumpScrollWait = () => {
  let current = null;

  const finish = (result) => {
    const waiter = current;

    current = null;

    if (waiter) {
      waiter.resolve(result);
    }
  };

  return {
    pending: () => !!current,

    arm (sessionId) {
      if (current) {
        finish({ scrollStatus: 'stale', reason: 'replaced' });
      }

      return new Promise(resolve => {
        current = { sessionId, resolve };
      });
    },

    notify (sessionId, scroll) {
      if (!current || current.sessionId !== sessionId || !scroll) {
        return false;
      }

      finish(scroll);
      return true;
    },

    cancel (result) {
      if (!current) {
        return false;
      }

      finish(result || { scrollStatus: 'stale', reason: 'stale' });
      return true;
    },
  };
};
