import { CancelToken } from 'axios';

const flights = new Map();

const flightKey = (timelineId, direction) => `${timelineId}:${direction}`;

export const claimWindowedHistoryFlight = (timelineId, direction) => {
  const key = flightKey(timelineId, direction);
  const previous = flights.get(key);

  if (previous) {
    previous.cancel();
  }

  const source = CancelToken.source();
  const flight = {
    cancelToken: source.token,
    cancel: () => source.cancel('windowed history closed'),
  };

  flights.set(key, flight);
  return flight;
};

export const releaseWindowedHistoryFlight = (timelineId, direction, flight) => {
  const key = flightKey(timelineId, direction);

  if (flights.get(key) === flight) {
    flights.delete(key);
  }
};

export const cancelWindowedHistory = (timelineId) => {
  ['newer', 'older', 'seek'].forEach(direction => {
    const key = flightKey(timelineId, direction);
    const flight = flights.get(key);

    if (flight) {
      flight.cancel();
      flights.delete(key);
    }
  });
};
