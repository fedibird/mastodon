import { SEEK_KIND, SEEK_PREFERENCE } from '../../timeline_seek/constants';
import {
  buildJumpQuery,
  interpretLocalDateTime,
  jumpModeState,
  jumpScrollDisposition,
  normalizeDecimalId,
} from '../model';

describe('timeline jump model', () => {
  it('sends a local date-time with its offset and rejects a bare date', () => {
    const parsed = interpretLocalDateTime('2026-10-17T09:30');
    const offsetMin = -new Date(2026, 9, 17, 9, 30, 0, 0).getTimezoneOffset();
    const sign = offsetMin >= 0 ? '+' : '-';
    const abs = Math.abs(offsetMin);
    const hours = String(Math.floor(abs / 60)).padStart(2, '0');
    const minutes = String(abs % 60).padStart(2, '0');

    expect(parsed.ok).toBe(true);
    expect(parsed.at).toBe(`2026-10-17T09:30:00${sign}${hours}:${minutes}`);
    expect(interpretLocalDateTime('2026-10-17')).toEqual({ ok: false, reason: 'date_only_rejected' });
  });

  it('rejects a local time that does not round-trip', () => {
    const createDate = () => new Date(2026, 2, 29, 3, 30, 0, 0);

    expect(interpretLocalDateTime('2026-03-29T02:30', createDate)).toEqual({
      ok: false,
      reason: 'nonexistent_local_time',
    });
  });

  it('keeps a large status id as a string and never accepts search text', () => {
    const id = '9223372036854775807';
    const built = buildJumpQuery({ mode: 'status', statusId: id });

    expect(normalizeDecimalId(id)).toEqual({ ok: true, id });
    expect(normalizeDecimalId('9223372036854775808').ok).toBe(false);
    expect(built.ok).toBe(true);
    expect(built.query.kind).toBe(SEEK_KIND.STATUS);
    expect(built.query.target.id).toBe(id);
    expect(built.payload).toEqual({ id });
    expect(buildJumpQuery({ mode: 'text', q: 'secret' })).toEqual({
      ok: false,
      reason: 'search_text_not_accepted',
    });
    expect(buildJumpQuery({ mode: 'text' }).reason).toBe('text_search_not_in_timeline');
  });

  it('builds an account jump from the id only and describes capabilities honestly', () => {
    const built = buildJumpQuery({
      mode: 'account',
      accountId: '42',
      preference: 'sideways',
    });

    expect(built.query.kind).toBe(SEEK_KIND.ACCOUNT);
    expect(built.query.preference).toBe(SEEK_PREFERENCE.NEAREST);
    expect(built.payload).toEqual({ account_id: '42' });
    expect(jumpModeState('home', 'date').level).toBe('approximate');
    expect(jumpModeState('home', 'date').reason).toBe('redis_id_probe_not_created_at');
    expect(jumpModeState('personal', 'account').canSubmit).toBe(false);
    expect(jumpModeState('public', 'status').level).toBe('supported');
    expect(jumpModeState('home', 'text').reason).toBe('text_search_not_in_timeline');
    expect(jumpModeState('mix', 'status').canSubmit).toBe(false);
  });

  it('restores history only when the row was not shown', () => {
    expect(jumpScrollDisposition({ scrollStatus: 'loaded' })).toBe('moved');
    expect(jumpScrollDisposition({ scrollStatus: 'filtered' })).toBe('restore');
    expect(jumpScrollDisposition({ reason: 'not_loaded' })).toBe('restore');
    expect(jumpScrollDisposition({ scrollStatus: 'user_scroll' })).toBe('cancelled_scroll');
  });
});
