import api from '../api';

export const ACCOUNT_NOTIFICATIONS_REQUEST = 'ACCOUNT_NOTIFICATIONS_REQUEST';
export const ACCOUNT_NOTIFICATIONS_SUCCESS = 'ACCOUNT_NOTIFICATIONS_SUCCESS';
export const ACCOUNT_NOTIFICATIONS_FAIL = 'ACCOUNT_NOTIFICATIONS_FAIL';

// A synchronous Redux lock is shared by every mounted profile of this account.
// Keep confirmed relationship values until the server acknowledges the change.
export const toggleAccountNotification = (id, key) => (dispatch, getState) => {
  if (key !== 'notify' && key !== 'notify_reblogs') return undefined;
  if (getState().getIn(['account_notifications', id], false)) return undefined;

  const relationship = getState().getIn(['relationships', id]);
  if (!relationship || !(relationship.get('following') || relationship.get('requested'))) return undefined;

  const field = key === 'notify' ? 'notifying' : 'notifying_reblogs';
  dispatch({ type: ACCOUNT_NOTIFICATIONS_REQUEST, id });

  return api(getState).post(`/api/v1/accounts/${id}/follow`, { [key]: !relationship.get(field, false) }).then(({ data }) => {
    dispatch({ type: ACCOUNT_NOTIFICATIONS_SUCCESS, id, relationship: data });
  }).catch(error => {
    dispatch({ type: ACCOUNT_NOTIFICATIONS_FAIL, id, error });
  });
};
