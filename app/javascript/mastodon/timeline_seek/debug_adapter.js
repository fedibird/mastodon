// Records scroll calls from a mounted list. The seek thunk does not scroll;
// StatusList moves once, on the frame after the committed window renders.

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
