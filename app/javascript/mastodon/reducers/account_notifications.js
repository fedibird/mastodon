import { Map as ImmutableMap } from 'immutable';
import {
  ACCOUNT_NOTIFICATIONS_REQUEST,
  ACCOUNT_NOTIFICATIONS_SUCCESS,
  ACCOUNT_NOTIFICATIONS_FAIL,
} from '../actions/account_notifications';

export default function accountNotifications(state = ImmutableMap(), action) {
  switch (action.type) {
  case ACCOUNT_NOTIFICATIONS_REQUEST:
    return state.set(action.id, true);
  case ACCOUNT_NOTIFICATIONS_SUCCESS:
  case ACCOUNT_NOTIFICATIONS_FAIL:
    return state.delete(action.id);
  default:
    return state;
  }
}
