import { reboostMenuItems, reboostRemainingSeconds, reboostWaitMinutes } from '../menu';

const intl = {
  formatMessage: (message, values) => {
    if (!values) {
      return message.defaultMessage;
    }

    return message.defaultMessage.replace('{minutes}', values.minutes).replace('{seconds}', values.seconds);
  },
};

const messages = {
  reboost: { defaultMessage: 'Reboost' },
  reboost_wait: { defaultMessage: 'Reboost (about {minutes} min left)' },
  cancel_reblog_private: { defaultMessage: 'Unboost' },
  reboost_hint: { defaultMessage: 'Turn on Group boosts if you do not want to see the same post repeatedly.' },
};

describe('reboost menu', () => {
  it('offers reboost and unreboost only as actions', () => {
    const status = { get: () => null };
    const items = reboostMenuItems({ intl, messages, status, onReboost: jest.fn(), onUnreblog: jest.fn(), busy: false });

    expect(items.map(item => item.text)).toEqual([
      'Reboost',
      'Unboost',
      'Turn on Group boosts if you do not want to see the same post repeatedly.',
    ]);
    expect(items[0].disabled).toBe(false);
    expect(items[2].disabled).toBe(true);
  });

  it('disables reboost during the cooldown and while a request is in flight', () => {
    const status = { get: (key) => key === 'reboost_retry_after' ? 61 : null };
    const items = reboostMenuItems({ intl, messages, status, onReboost: jest.fn(), onUnreblog: jest.fn(), busy: false });

    expect(reboostWaitMinutes(61)).toBe(2);
    expect(reboostWaitMinutes(1)).toBe(1);
    expect(reboostWaitMinutes(0)).toBe(0);
    expect(items[0].text).toBe('Reboost (about 2 min left)');
    expect(items[0].disabled).toBe(true);
    expect(items[1].disabled).toBeUndefined();

    const busy = reboostMenuItems({ intl, messages, status: { get: () => null }, onReboost: jest.fn(), onUnreblog: jest.fn(), busy: true });
    expect(busy[0].disabled).toBe(true);
  });

  it('enables reboost after the stored deadline without a reload', () => {
    jest.useFakeTimers('modern');
    jest.setSystemTime(new Date('2026-11-24T00:00:00Z'));
    const until = Date.now() + (5 * 60 * 1000);
    const status = { get: (key) => key === 'reboost_retry_until' ? until : null };
    const messagesWithCheck = { ...messages, reboost_check: { defaultMessage: 'Check status' } };

    expect(reboostMenuItems({ intl, messages, status, onReboost: jest.fn(), onUnreblog: jest.fn(), busy: false })[0].disabled).toBe(true);

    jest.setSystemTime(new Date('2026-11-24T00:05:00Z'));
    const later = reboostMenuItems({ intl, messages, status, onReboost: jest.fn(), onUnreblog: jest.fn(), busy: false });
    expect(reboostRemainingSeconds(status)).toBe(0);
    expect(later[0].text).toBe('Reboost');
    expect(later[0].disabled).toBe(false);

    const pending = {
      get: (key) => key === 'reboost_operation' ? { get: (name) => name === 'id' ? '9' : 'pending' } : null,
    };
    const checked = reboostMenuItems({ intl, messages: messagesWithCheck, status: pending, onReboost: jest.fn(), onUnreblog: jest.fn(), onCheck: jest.fn(), busy: true });
    expect(checked.map(item => item.text)).toContain('Check status');
    jest.useRealTimers();
  });
});
