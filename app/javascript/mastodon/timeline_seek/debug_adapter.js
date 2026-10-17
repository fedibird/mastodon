// Test and future-UI adapter. P2 does not mount a seek control.

export const createTimelineSeekTestAdapter = () => {
  const calls = [];

  return {
    calls,
    scrollToStatus(statusId) {
      calls.push(statusId);
      return { ok: true, scrolled: true, statusId };
    },
  };
};
