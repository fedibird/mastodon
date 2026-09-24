jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

jest.mock('intl-messageformat', () => function IntlMessageFormat() {
  return { format: () => 'title' };
});

import reducer from '../notifications';
import { NOTIFICATIONS_UPDATE } from '../../actions/notifications';

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
});
