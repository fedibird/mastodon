jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

jest.mock('intl-messageformat', () => function IntlMessageFormat() {
  return { format: () => 'title' };
});

import reducer from '../notifications';
import { NOTIFICATIONS_UPDATE, NOTIFICATIONS_EXPAND_SUCCESS, NOTIFICATIONS_LOAD_PENDING } from '../../actions/notifications';

describe('notification normalization', () => {
  it('stores report, reporter, and target account for admin.report', () => {
    const state = reducer(undefined, {
      type: NOTIFICATIONS_UPDATE,
      notification: {
        id: '10',
        type: 'admin.report',
        created_at: '2026-01-01T00:00:00.000Z',
        account: { id: '2' },
        report: {
          id: '9',
          target_account: { id: '3', acct: 'bob' },
        },
      },
    });

    const item = state.getIn(['items', 0]);

    expect(item.get('type')).toEqual('admin.report');
    expect(item.get('account')).toEqual('2');
    expect(item.getIn(['report', 'id'])).toEqual('9');
    expect(item.getIn(['report', 'target_account', 'acct'])).toEqual('bob');
  });

  it('stores the edited status id for update', () => {
    const state = reducer(undefined, {
      type: NOTIFICATIONS_UPDATE,
      notification: {
        id: '11',
        type: 'update',
        created_at: '2026-01-01T00:00:00.000Z',
        account: { id: '4' },
        status: { id: '8' },
      },
    });

    expect(state.getIn(['items', 0, 'status'])).toEqual('8');
    expect(state.getIn(['items', 0, 'type'])).toEqual('update');
  });

  const followedBoost = {
    id: '12', type: 'status', account: { id: 'booster' },
    status: { id: 'wrapper', reblog: { id: 'original' } },
  };

  it.each([false, true])('keeps the status type and wrapper on streaming receive (pending=%s)', usePendingItems => {
    let state = reducer(undefined, { type: NOTIFICATIONS_UPDATE, notification: followedBoost, usePendingItems });
    const key = usePendingItems ? 'pendingItems' : 'items';
    expect(state.getIn([key, 0, 'type'])).toBe('status');
    expect(state.getIn([key, 0, 'status'])).toBe('wrapper');
    expect(state.get('unread')).toBe(1);
    if (usePendingItems) {
      state = reducer(state, { type: NOTIFICATIONS_LOAD_PENDING });
      expect(state.getIn(['items', 0, 'status'])).toBe('wrapper');
      expect(state.get('pendingItems').size).toBe(0);
    }
  });

  it.each([false, true])('keeps the wrapper during history/recent loading (recent=%s)', isLoadingRecent => {
    const state = reducer(undefined, { type: NOTIFICATIONS_EXPAND_SUCCESS, notifications: [followedBoost], isLoadingRecent, usePendingItems: true });
    const key = isLoadingRecent ? 'pendingItems' : 'items';
    expect(state.getIn([key, 0, 'type'])).toBe('status');
    expect(state.getIn([key, 0, 'status'])).toBe('wrapper');
  });
});
