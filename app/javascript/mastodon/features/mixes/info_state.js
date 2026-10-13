export const mixTimelineLocation = (mixId, created) => {
  const pathname = `/timelines/mixes/${mixId}`;

  if (!created) {
    return pathname;
  }

  return {
    pathname,
    state: { openInfoOnFirstView: true },
  };
};

export const mixInfoStartsOpen = (location) => !!(
  location && location.state && location.state.openInfoOnFirstView
);

export const consumeMixInfoFlag = (history, location) => {
  if (!history || !history.replace || !mixInfoStartsOpen(location)) {
    return false;
  }

  history.replace({
    pathname: location.pathname,
    search: location.search,
    hash: location.hash,
    state: {
      ...location.state,
      openInfoOnFirstView: false,
    },
  });

  return true;
};
