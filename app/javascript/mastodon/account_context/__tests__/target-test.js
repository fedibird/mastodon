import { fromJS } from 'immutable';

import { accountContextSurfaceKey, accountContextTarget, reblogWrapperTarget } from '../target';

const wrapperId = '9007199254740993';
const originalId = '9007199254740991';
const quoteId = '9007199254740888';
const referenceId = '9007199254740777';

const plainBoost = {
  id: wrapperId,
  account: { id: '42' },
  reblog: {
    id: originalId,
    account: { id: '7' },
    quote: { id: quoteId, account: { id: '9' } },
    in_reply_to_id: '5',
    status_reference_ids: [referenceId, quoteId],
  },
};

describe('accountContextTarget', () => {
  it('anchors a boost on the wrapper id and keeps reblogs', () => {
    expect(accountContextTarget({ kind: 'boost', status: fromJS(plainBoost) })).toEqual({
      available: true,
      reason: 'ready',
      kind: 'boost',
      accountId: '42',
      statusId: wrapperId,
      reply: false,
      reblog: true,
    });
  });

  it('does not use the original id when the row is not a wrapper', () => {
    const target = accountContextTarget({
      kind: 'boost',
      status: fromJS({ id: originalId, account: { id: '7' } }),
    });

    expect(target.available).toBe(false);
    expect(target.reason).toBe('not_a_wrapper');
    expect(target.statusId).toBeNull();
  });

  it('anchors a quote on the quoting status, including a reply inside a boost', () => {
    const wrapped = accountContextTarget({ kind: 'quote', status: fromJS(plainBoost) });
    const direct = accountContextTarget({
      kind: 'quote',
      status: fromJS({
        id: originalId,
        account: { id: '7' },
        in_reply_to_id: '5',
        quote_id: quoteId,
      }),
    });

    expect(wrapped).toMatchObject({
      available: true,
      kind: 'quote',
      accountId: '7',
      statusId: originalId,
      reply: true,
      reblog: false,
    });
    expect(wrapped.statusId).not.toBe(quoteId);
    expect(direct.statusId).toBe(originalId);
    expect(direct.reply).toBe(true);
  });

  it('does not treat the quoted post as the quoter', () => {
    const target = accountContextTarget({
      kind: 'quote',
      status: fromJS({ id: quoteId, account: { id: '9' } }),
    });

    expect(target.available).toBe(false);
    expect(target.reason).toBe('not_a_quote');
  });

  it('anchors a reference on the referencing status and keeps non-quote references', () => {
    const target = accountContextTarget({ kind: 'reference', status: fromJS(plainBoost) });

    expect(target).toMatchObject({
      available: true,
      kind: 'reference',
      accountId: '7',
      statusId: originalId,
      reply: true,
      reblog: false,
    });
    expect(target.statusId).not.toBe(referenceId);
  });

  it('ignores a reference list that only repeats the quote', () => {
    const target = accountContextTarget({
      kind: 'reference',
      status: fromJS({
        id: originalId,
        account: { id: '7' },
        quote_id: quoteId,
        status_reference_ids: [quoteId],
        status_references_count: 1,
      }),
    });

    expect(target.available).toBe(false);
    expect(target.reason).toBe('not_a_reference');
  });

  it('rejects numeric ids instead of coercing them', () => {
    const target = accountContextTarget({
      kind: 'boost',
      status: { id: 12, account: { id: '4' }, reblog: { id: '9' } },
    });

    expect(target.available).toBe(false);
  });
});

describe('reblogWrapperTarget', () => {
  const originalStatusId = originalId;

  it('uses a resolved wrapper id', () => {
    expect(reblogWrapperTarget({
      accountId: '42',
      originalStatusId,
      resolution: { state: 'resolved', id: wrapperId, account_id: '42' },
    })).toMatchObject({
      available: true,
      statusId: wrapperId,
      accountId: '42',
      reblog: true,
      reply: false,
    });
  });

  it('does not substitute the original status id', () => {
    ['absent', 'unavailable', 'unknown'].forEach(state => {
      const target = reblogWrapperTarget({
        accountId: '42',
        originalStatusId,
        resolution: { state, id: null },
      });

      expect(target.available).toBe(false);
      expect(target.statusId).toBeNull();
      expect(target.reason).toBe(state);
    });

    const substituted = reblogWrapperTarget({
      accountId: '42',
      originalStatusId,
      resolution: { state: 'resolved', id: originalStatusId, account_id: '42' },
    });

    expect(substituted.available).toBe(false);
    expect(substituted.reason).toBe('unknown');
    expect(substituted.statusId).toBeNull();
  });

  it('keeps an ambiguous lookup distinct from a missing boost', () => {
    expect(reblogWrapperTarget({
      accountId: '42',
      originalStatusId,
      resolution: { state: 'unknown', reason: 'ambiguous', id: wrapperId },
    }).reason).toBe('ambiguous');
  });
});

describe('accountContextSurfaceKey', () => {
  it('keeps split timeline ids and rejects profile timeline ids', () => {
    expect(accountContextSurfaceKey('home:split:column:session')).toBe('home:split:column:session');
    expect(accountContextSurfaceKey('account:42')).toBeNull();
    expect(accountContextSurfaceKey('')).toBeNull();
  });
});
