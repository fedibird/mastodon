import { List as ImmutableList, fromJS } from 'immutable';

import { NOTIFICATION_FILTERS_FETCH_SUCCESS } from '../actions/notification_filters';

export default function notificationFilters(state = ImmutableList(), action) {
  switch(action.type) {
  case NOTIFICATION_FILTERS_FETCH_SUCCESS:
    return fromJS(action.filters);
  default:
    return state;
  }
};
