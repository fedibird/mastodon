import { fromJS } from 'immutable';
import {
  buildGroupImmediateView,
  buildHashtagImmediateView,
  groupStatusEligible,
  hashtagStatusEligible,
  immediateStatusDecision,
  isLocalFedibirdGroupContext,
  statusMatchesImmediateView,
} from '../eligibility';
import { groupPostingContext } from '../../posting_context/fixtures/group_context_fixture';
import { mitraGroupPostingContext } from '../../posting_context/fixtures/mitra_group_context_fixture';

const status = (overrides = {}) => ({
  id: '10',
  visibility: 'public',
  reblog: null,
  tags: [{ name: 'News' }],
  mentions: [],
  media_attachments: [],
  account: { id: '1', bot: false, suspended: false, limited: false },
  ...overrides,
});

describe('hashtag immediate eligibility', () => {
  const filters = {
    primary: '#News',
    any: ['Web'],
    all: ['Fedibird'],
    none: ['Spam'],
  };

  it('matches the primary tag with the existing hashtag normalization', () => {
    expect(hashtagStatusEligible(status({
      tags: [{ name: 'news' }, { name: 'fedibird' }],
    }), { primary: '＃News', any: [], all: [], none: [] }).eligible).toBe(true);
  });

  it('accepts an any-tag and requires every all-tag', () => {
    expect(hashtagStatusEligible(status({
      tags: [{ name: 'web' }, { name: 'fedibird' }],
    }), filters).eligible).toBe(true);

    expect(hashtagStatusEligible(status({
      tags: [{ name: 'news' }, { name: 'fedibird' }],
    }), filters).eligible).toBe(true);

    expect(hashtagStatusEligible(status({
      tags: [{ name: 'news' }],
    }), filters).reason).toBe('tags-all');
  });

  it('rejects a none-tag, a non-public post, a reblog, and a silenced or bot account', () => {
    expect(hashtagStatusEligible(status({
      tags: [{ name: 'news' }, { name: 'fedibird' }, { name: 'spam' }],
    }), filters).reason).toBe('tags-none');
    expect(hashtagStatusEligible(status({ visibility: 'unlisted' }), filters).reason).toBe('visibility');
    expect(hashtagStatusEligible(status({ visibility_ex: 'limited' }), filters).reason).toBe('visibility');
    expect(hashtagStatusEligible(status({ reblog: { id: '9' } }), filters).reason).toBe('reblog');
    expect(hashtagStatusEligible(status({ account: { id: '1', limited: true } }), filters).reason).toBe('silenced');
    expect(hashtagStatusEligible(status({ account: { id: '1', bot: true } }), filters, { hideBot: true }).reason).toBe('bot');
    expect(hashtagStatusEligible(status({
      account: { id: '1', bot: true },
      tags: [{ name: 'news' }, { name: 'fedibird' }],
    }), filters, { hideBot: false }).eligible).toBe(true);
  });

  it('uses only the first four names in each tag mode', () => {
    const limited = {
      primary: 'news',
      any: [],
      all: ['a', 'b', 'c', 'd', 'e'],
      none: [],
    };

    expect(hashtagStatusEligible(status({
      tags: ['news', 'a', 'b', 'c', 'd'].map(name => ({ name })),
    }), limited).eligible).toBe(true);

    expect(hashtagStatusEligible(status({
      tags: ['news', 'a', 'b', 'c'].map(name => ({ name })),
    }), limited).reason).toBe('tags-all');
  });

  it('keeps replies when they carry the tag', () => {
    expect(hashtagStatusEligible(status({
      in_reply_to_id: '4',
      tags: [{ name: 'news' }],
    }), { primary: 'news', any: [], all: [], none: [] }).eligible).toBe(true);
  });
});

describe('group immediate eligibility', () => {
  const context = groupPostingContext;
  const filters = {
    groupId: '123',
    onlyMedia: false,
    withoutMedia: false,
    tagged: null,
    viewPermission: null,
  };

  it('recognizes only a consistent local Fedibird group', () => {
    expect(isLocalFedibirdGroupContext(context, '123')).toBe(true);
    expect(isLocalFedibirdGroupContext(mitraGroupPostingContext, '123')).toBe(false);
    expect(isLocalFedibirdGroupContext(context, '999')).toBe(false);
  });

  it('inserts a public or unlisted mention that satisfies media and tag filters', () => {
    expect(groupStatusEligible(status({
      visibility: 'unlisted',
      mentions: [{ id: '123' }],
    }), filters, { localGroup: true }).eligible).toBe(true);

    expect(groupStatusEligible(status({
      mentions: [{ id: '123' }],
      media_attachments: [{ id: 'm' }],
      tags: [{ name: 'Photos' }],
    }), { ...filters, onlyMedia: true, tagged: '#photos' }, { localGroup: true }).eligible).toBe(true);
  });

  it('skips remote groups, missing mentions, visibility, blocks, and contradictory filters', () => {
    expect(groupStatusEligible(status({ mentions: [{ id: '123' }] }), filters, { localGroup: false }).reason).toBe('remote-group');
    expect(groupStatusEligible(status(), filters, { localGroup: true }).reason).toBe('group-not-mentioned');
    expect(groupStatusEligible(status({
      visibility: 'private',
      mentions: [{ id: '123' }],
    }), filters, { localGroup: true }).reason).toBe('visibility');
    expect(groupStatusEligible(status({ mentions: [{ id: '123' }] }), filters, { localGroup: true, blockedByGroup: true }).reason).toBe('blocked-by-group');
    expect(groupStatusEligible(status({ mentions: [{ id: '123' }] }), { ...filters, viewPermission: 'unknown' }, { localGroup: true }).reason).toBe('view-permission');
    expect(groupStatusEligible(status({ mentions: [{ id: '123' }] }), { ...filters, onlyMedia: true, withoutMedia: true }, { localGroup: true }).reason).toBe('media-conflict');
    expect(groupStatusEligible(status({
      mentions: [{ id: '123' }],
      media_attachments: [{ id: 'm' }],
    }), { ...filters, withoutMedia: true }, { localGroup: true }).reason).toBe('media-excluded');
    expect(groupStatusEligible(status({ mentions: [{ id: '123' }] }), { ...filters, onlyMedia: true }, { localGroup: true }).reason).toBe('media-required');
    expect(groupStatusEligible(status({ mentions: [{ id: '123' }] }), { ...filters, tagged: 'missing' }, { localGroup: true }).reason).toBe('tagged-mismatch');
  });
});

describe('immediate view signatures', () => {
  it('gives different hashtag columns different signatures when their tag filters differ', () => {
    const open = buildHashtagImmediateView({
      viewKey: 'portable:hashtag-column:a',
      timelineId: 'hashtag:News',
      primary: 'News',
      tags: {},
    });
    const narrowed = buildHashtagImmediateView({
      viewKey: 'portable:hashtag-column:b',
      timelineId: 'hashtag:News',
      primary: 'News',
      tags: { all: [{ value: 'Dev' }] },
    });

    expect(open.timelineId).toBe(narrowed.timelineId);
    expect(open.filterSignature).not.toBe(narrowed.filterSignature);
  });

  it('stores the local group flag on the group view', () => {
    const local = buildGroupImmediateView({
      viewKey: 'portable:group-route:123',
      timelineId: 'group:123',
      groupId: '123',
      onlyMedia: false,
      withoutMedia: true,
      tagged: null,
      postingContext: groupPostingContext,
    });
    const remote = buildGroupImmediateView({
      viewKey: 'portable:group-route:9',
      timelineId: 'group:9',
      groupId: '9',
      postingContext: mitraGroupPostingContext,
    });

    expect(local.localGroup).toBe(true);
    expect(local.filterSignature).toContain('without');
    expect(remote.localGroup).toBe(false);
    expect(immediateStatusDecision({
      kind: 'group',
      localGroup: remote.localGroup,
      filters: remote.filters,
    }, status({ mentions: [{ id: '9' }] })).reason).toBe('remote-group');
  });

  it('matches a registered view from an immutable record', () => {
    const view = fromJS(buildHashtagImmediateView({
      viewKey: 'portable:hashtag-route:news',
      timelineId: 'hashtag:news',
      primary: 'news',
      tags: {},
    }));
    expect(statusMatchesImmediateView(view, status({ tags: [{ name: 'NEWS' }] }))).toBe(true);
    expect(statusMatchesImmediateView(view, status({ visibility: 'unlisted' }))).toBe(false);
  });
});
