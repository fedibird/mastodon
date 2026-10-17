const surfaces = new Map();

const slotFor = (id) => {
  let slot = surfaces.get(id);

  if (!slot) {
    slot = {
      api: null,
      listeners: new Set(),
      resume: null,
      completion: null,
    };
    surfaces.set(id, slot);
  }

  return slot;
};

const dropIfIdle = (id) => {
  const slot = surfaces.get(id);

  if (!slot) {
    return;
  }

  if (!slot.api && slot.listeners.size === 0 && !slot.resume && !slot.completion) {
    surfaces.delete(id);
  }
};

export const bindHistorySurface = (id, api) => {
  if (!id || !api) {
    return () => {};
  }

  const slot = slotFor(id);

  slot.api = api;

  return () => {
    const current = surfaces.get(id);

    if (current && current.api === api) {
      current.api = null;
      dropIfIdle(id);
    }
  };
};

export const captureHistorySurface = (id) => {
  const slot = surfaces.get(id);

  if (!slot || !slot.api || typeof slot.api.capture !== 'function') {
    return null;
  }

  return slot.api.capture();
};

export const restoreHistorySurface = (id, anchor, options) => {
  const slot = surfaces.get(id);

  if (!slot || !slot.api || typeof slot.api.restore !== 'function') {
    return { ok: false, reason: 'not_mounted', moved: false };
  }

  return slot.api.restore(anchor, options);
};

export const subscribeHistorySurface = (id, listener) => {
  if (!id || typeof listener !== 'function') {
    return () => {};
  }

  const slot = slotFor(id);

  slot.listeners.add(listener);

  return () => {
    const current = surfaces.get(id);

    if (!current) {
      return;
    }

    current.listeners.delete(listener);
    dropIfIdle(id);
  };
};

export const emitHistorySurfaceScroll = (id) => {
  const slot = surfaces.get(id);

  if (!slot) {
    return;
  }

  slot.listeners.forEach(listener => {
    listener({ type: 'scroll' });
  });
};

export const emitHistorySurfaceUnmount = (id, anchor) => {
  const slot = surfaces.get(id);

  if (!slot) {
    return;
  }

  slot.listeners.forEach(listener => {
    listener({ type: 'unmount', anchor });
  });
};

export const armSurfaceResume = (id, resume) => {
  if (!id) {
    return;
  }

  slotFor(id).resume = resume || null;
};

export const peekSurfaceResume = (id) => {
  const slot = surfaces.get(id);

  return slot && slot.resume ? slot.resume : null;
};

export const clearSurfaceResume = (id, requestId) => {
  const slot = surfaces.get(id);

  if (!slot || !slot.resume) {
    return;
  }

  if (!requestId || slot.resume.requestId === requestId) {
    slot.resume = null;
    dropIfIdle(id);
  }
};

export const subscribeResumeCompletion = (id, requestId, listener) => {
  if (!id || typeof listener !== 'function') {
    return () => {};
  }

  const slot = slotFor(id);
  const wrapped = (result) => {
    if (!requestId || result.requestId === requestId) {
      listener(result);
    }
  };

  slot.completion = wrapped;

  return () => {
    const current = surfaces.get(id);

    if (current && current.completion === wrapped) {
      current.completion = null;
      dropIfIdle(id);
    }
  };
};

export const completeSurfaceResume = (id, result) => {
  const slot = surfaces.get(id);

  if (!slot) {
    return;
  }

  const listener = slot.completion;

  slot.resume = null;

  if (listener) {
    slot.completion = null;
    listener(result || {});
  }

  dropIfIdle(id);
};

export const resetHistorySurfaces = () => {
  surfaces.clear();
};
