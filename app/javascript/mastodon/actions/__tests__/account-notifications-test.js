import { createStore, applyMiddleware } from 'redux';
import { combineReducers } from 'redux-immutable';
import thunk from 'redux-thunk';
import { fromJS } from 'immutable';
import api from '../../api';
import { toggleAccountNotification, ACCOUNT_NOTIFICATIONS_FAIL } from '../account_notifications';
import pending from '../../reducers/account_notifications';
import relationships from '../../reducers/relationships';
import { RELATIONSHIPS_FETCH_SUCCESS } from '../accounts';

jest.mock('../../api', () => ({ __esModule: true, default: jest.fn() }));
jest.mock('react-intl', () => ({ defineMessages: messages => messages }));

const relationship = (id = '1', changes = {}) => ({
  id, following: true, requested: false, notifying: false, notifying_reblogs: false,
  showing_reblogs: false, delivery: false, languages: ['ja'], ...changes,
});
const deferred = () => {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => {
    resolve = yes; reject = no;
  });
  return { promise, resolve, reject };
};
const setup = (...values) => {
  const actions = [];
  const capture = () => next => action => {
    actions.push(action); return next(action);
  };
  const store = createStore(combineReducers({ relationships, account_notifications: pending }), fromJS({ relationships: Object.fromEntries(values.map(value => [value.id, value])) }), applyMiddleware(thunk, capture));
  const post = jest.fn();
  api.mockReturnValue({ post });
  return { store, post, actions };
};

describe('per-account notification settings', () => {
  it.each([
    ['notify', false, false], ['notify', true, false],
    ['notify_reblogs', false, false], ['notify_reblogs', false, true],
  ])('sends only %s and keeps confirmed server values until success (%s/%s)', async (key, notifying, notifying_reblogs) => {
    const before = relationship('1', { notifying, notifying_reblogs });
    const { store, post } = setup(before);
    const request = deferred();
    post.mockReturnValue(request.promise);
    const result = store.dispatch(toggleAccountNotification('1', key));
    const field = key === 'notify' ? 'notifying' : 'notifying_reblogs';
    expect(post).toHaveBeenCalledWith('/api/v1/accounts/1/follow', { [key]: !before[field] });
    expect(store.getState().getIn(['relationships', '1']).toJS()).toEqual(before);
    expect(store.getState().getIn(['account_notifications', '1'])).toBe(true);
    request.resolve({ data: { ...before, [field]: !before[field] } });
    await result;
    const after = store.getState().getIn(['relationships', '1']);
    expect(after.get(field)).toBe(!before[field]);
    expect(after.get(field === 'notifying' ? 'notifying_reblogs' : 'notifying')).toBe(before[field === 'notifying' ? 'notifying_reblogs' : 'notifying']);
    expect(after.get('showing_reblogs')).toBe(false);
    expect(after.get('delivery')).toBe(false);
    expect(after.get('languages').toJS()).toEqual(['ja']);
    expect(store.getState().getIn(['account_notifications', '1'], false)).toBe(false);
  });

  it('drops duplicate and concurrent toggles while saving, then uses the acknowledged value', async () => {
    const { store, post } = setup(relationship());
    const first = deferred();
    post.mockReturnValueOnce(first.promise).mockResolvedValueOnce({ data: relationship('1', { notifying: true, notifying_reblogs: true }) });
    const saving = store.dispatch(toggleAccountNotification('1', 'notify'));
    store.dispatch(toggleAccountNotification('1', 'notify'));
    store.dispatch(toggleAccountNotification('1', 'notify_reblogs'));
    expect(post).toHaveBeenCalledTimes(1);
    first.resolve({ data: relationship('1', { notifying: true }) });
    await saving;
    await store.dispatch(toggleAccountNotification('1', 'notify_reblogs'));
    expect(post).toHaveBeenLastCalledWith('/api/v1/accounts/1/follow', { notify_reblogs: true });
    expect(store.getState().getIn(['relationships', '1', 'notifying'])).toBe(true);
    expect(store.getState().getIn(['relationships', '1', 'notifying_reblogs'])).toBe(true);
  });

  it('keeps following, requested and notification values on failure and enables retry', async () => {
    const before = relationship('1', { following: false, requested: true, notifying: true });
    const { store, post, actions } = setup(before);
    const error = new Error('offline');
    post.mockRejectedValueOnce(error).mockResolvedValueOnce({ data: { ...before, notifying_reblogs: true } });
    await store.dispatch(toggleAccountNotification('1', 'notify_reblogs'));
    expect(store.getState().getIn(['relationships', '1']).toJS()).toEqual(before);
    expect(actions).toContainEqual({ type: ACCOUNT_NOTIFICATIONS_FAIL, id: '1', error });
    await store.dispatch(toggleAccountNotification('1', 'notify_reblogs'));
    expect(store.getState().getIn(['relationships', '1', 'requested'])).toBe(true);
    expect(store.getState().getIn(['relationships', '1', 'notifying_reblogs'])).toBe(true);
  });

  it('allows different accounts in parallel without cross-account rollback on reversed responses', async () => {
    const { store, post } = setup(relationship('1'), relationship('2'));
    const first = deferred();
    const second = deferred();
    post.mockReturnValueOnce(first.promise).mockReturnValueOnce(second.promise);
    const a = store.dispatch(toggleAccountNotification('1', 'notify'));
    const b = store.dispatch(toggleAccountNotification('2', 'notify_reblogs'));
    second.resolve({ data: relationship('2', { notifying_reblogs: true }) });
    await b;
    first.resolve({ data: relationship('1', { notifying: true }) });
    await a;
    expect(store.getState().getIn(['relationships', '1', 'notifying'])).toBe(true);
    expect(store.getState().getIn(['relationships', '2', 'notifying_reblogs'])).toBe(true);
  });

  it('uses newly fetched server values, including after revisiting a profile', async () => {
    const { store, post } = setup(relationship());
    store.dispatch({ type: RELATIONSHIPS_FETCH_SUCCESS, relationships: [relationship('1', { notifying_reblogs: true })] });
    post.mockResolvedValue({ data: relationship() });
    await store.dispatch(toggleAccountNotification('1', 'notify_reblogs'));
    expect(post).toHaveBeenCalledWith('/api/v1/accounts/1/follow', { notify_reblogs: false });
  });

  it('does not follow an unfollowed account or accept unrelated options', () => {
    const { store, post } = setup(relationship('1', { following: false }));
    store.dispatch(toggleAccountNotification('1', 'notify'));
    store.dispatch(toggleAccountNotification('2', 'notify_reblogs'));
    store.dispatch(toggleAccountNotification('1', 'delivery'));
    expect(post).not.toHaveBeenCalled();
  });
});
