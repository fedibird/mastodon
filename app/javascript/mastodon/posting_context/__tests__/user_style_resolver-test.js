import { List as ImmutableList, Map as ImmutableMap, Set as ImmutableSet, fromJS } from 'immutable';
import { resolveUserPostingStyle } from '../user_style_resolver';

const composer = (extra = {}) => ImmutableMap({
  text: '',
  privacy: 'public',
  default_privacy: 'public',
  language: 'ja',
  default_language: 'ja',
  spoiler: false,
  spoiler_text: '',
  sensitive: false,
  media_attachments: ImmutableList(),
  poll: null,
  in_reply_to: null,
  quote_from: null,
  id: null,
  scheduled_status_id: null,
  userPostingStyle: ImmutableMap({
    manualFields: ImmutableSet(),
    destinationSource: null,
    destinationStatus: 'idle',
    destinationAccountId: null,
  }),
}).merge(fromJS(extra));

const style = (extra = {}) => fromJS({
  id: '1',
  revision: 3,
  target: { kind: 'none', accountId: null, hashtag: null, label: null },
  defaults: {},
  ...extra,
});

describe('resolveUserPostingStyle', () => {
  it('applies explicit defaults and treats auto language as clearing the language', () => {
    const plan = resolveUserPostingStyle(style({
      defaults: {
        visibility: 'private',
        language: { mode: 'auto' },
        sensitive: true,
        spoiler: { enabled: true, text: 'note' },
      },
    }), composer());

    expect(plan.blocked).toBe(false);
    expect(plan.fields).toEqual({
      privacy: 'private',
      language: null,
      spoiler: true,
      spoilerText: 'note',
      sensitive: true,
    });
    expect(plan.needsConfirmation).toBe(false);
  });

  it('leaves inherited language and visibility unchanged', () => {
    const plan = resolveUserPostingStyle(style(), composer());

    expect(plan.fields.language).toBeUndefined();
    expect(plan.fields.privacy).toBeUndefined();
    expect(plan.ownedFields).toEqual([]);
  });

  it('releases a previous style value when the next style inherits that field', () => {
    const drafted = composer({
      privacy: 'private',
      language: 'en',
      spoiler: true,
      spoiler_text: 'note',
      sensitive: true,
      userPostingStyle: {
        manualFields: [],
        styleOwnedFields: ['privacy', 'language', 'spoiler', 'sensitive'],
        destinationSource: null,
        destinationStatus: 'idle',
        destinationAccountId: null,
      },
    });
    const plan = resolveUserPostingStyle(style(), drafted);

    expect(plan.fields).toEqual({
      privacy: 'public',
      language: 'ja',
      spoiler: false,
      spoilerText: '',
      sensitive: false,
    });
    expect(plan.ownedFields).toEqual([]);
  });

  it('keeps a manual value when the next style inherits that field', () => {
    const drafted = composer({
      privacy: 'unlisted',
      userPostingStyle: {
        manualFields: ['privacy'],
        styleOwnedFields: ['privacy'],
        destinationSource: null,
        destinationStatus: 'idle',
        destinationAccountId: null,
      },
    });
    const plan = resolveUserPostingStyle(style(), drafted);

    expect(plan.fields.privacy).toBeUndefined();
    expect(plan.unapplied).toEqual([]);
    expect(plan.ownedFields).toEqual([]);
  });

  it('uses the server sensitive value when a content warning has text', () => {
    const plan = resolveUserPostingStyle(style({
      defaults: {
        sensitive: false,
        spoiler: { enabled: true, text: 'cw' },
      },
    }), composer({
      media_attachments: [{ id: 'media-1' }],
    }));

    expect(plan.fields.spoiler).toBe(true);
    expect(plan.fields.spoilerText).toEqual('cw');
    expect(plan.fields.sensitive).toBe(true);
    expect(plan.ownedFields).toEqual(expect.arrayContaining(['spoiler', 'sensitive']));
    expect(plan.unapplied).toEqual([]);
  });

  it('keeps an explicit sensitive off when the content warning has no text', () => {
    const plan = resolveUserPostingStyle(style({
      defaults: {
        sensitive: false,
        spoiler: { enabled: true, text: '  ' },
      },
    }), composer({
      media_attachments: [{ id: 'media-1' }],
      default_sensitive: true,
    }));

    expect(plan.fields.spoiler).toBe(true);
    expect(plan.fields.sensitive).toBeUndefined();
    expect(plan.ownedFields).toContain('sensitive');
  });

  it('retries the same failed group without asking for confirmation', () => {
    const plan = resolveUserPostingStyle(style({
      target: { kind: 'group', accountId: '9', hashtag: null, label: 'group' },
    }), composer({
      text: 'Hello',
      userPostingStyle: {
        manualFields: [],
        styleOwnedFields: [],
        destinationSource: 'style',
        destinationStatus: 'failed',
        destinationAccountId: '9',
      },
    }));

    expect(plan.destination.action).toEqual('group');
    expect(plan.destination.changes).toBe(false);
    expect(plan.needsConfirmation).toBe(false);
  });

  it('uses the account sensitive default when media is already attached', () => {
    const drafted = composer({
      sensitive: true,
      default_sensitive: true,
      media_attachments: ImmutableList([ImmutableMap({ id: 'media-1' })]),
      userPostingStyle: {
        manualFields: [],
        styleOwnedFields: ['sensitive'],
        destinationSource: null,
        destinationStatus: 'idle',
        destinationAccountId: null,
      },
    });
    const plan = resolveUserPostingStyle(null, drafted);

    expect(plan.fields.sensitive).toBeUndefined();
    expect(plan.ownedFields).toEqual([]);
  });

  it('keeps manually edited fields and reports them as unapplied', () => {
    const drafted = composer({
      text: 'Hello',
      privacy: 'unlisted',
      userPostingStyle: {
        manualFields: ['privacy'],
        destinationSource: null,
        destinationStatus: 'idle',
        destinationAccountId: null,
      },
    });
    const plan = resolveUserPostingStyle(style({
      defaults: { visibility: 'private', language: { mode: 'explicit', code: 'en' } },
    }), drafted);

    expect(plan.fields.privacy).toBeUndefined();
    expect(plan.fields.language).toEqual('en');
    expect(plan.unapplied).toEqual(['privacy']);
    expect(plan.needsConfirmation).toBe(false);
  });

  it('asks before a group destination or visibility change on a draft', () => {
    const drafted = composer({ text: 'Hello' });
    const plan = resolveUserPostingStyle(style({
      target: { kind: 'group', accountId: '123', label: 'localsquad' },
      defaults: { visibility: 'private' },
    }), drafted);

    expect(plan.destination).toMatchObject({ action: 'group', accountId: '123', changes: true });
    expect(plan.needsConfirmation).toBe(true);
  });

  it('does not retarget a reply and does not apply the style there', () => {
    const plan = resolveUserPostingStyle(style({
      target: { kind: 'group', accountId: '123', label: 'localsquad' },
      defaults: { visibility: 'private' },
    }), composer({ in_reply_to: 's1', text: '@bob ' }));

    expect(plan.blocked).toBe(false);
    expect(plan.destination.action).toEqual('skip');
    expect(plan.fields.privacy).toBeUndefined();
    expect(plan.unapplied).toEqual(expect.arrayContaining(['privacy', 'destination']));
    expect(plan.needsConfirmation).toBe(false);
  });

  it('does not apply a style while editing', () => {
    expect(resolveUserPostingStyle(style(), composer({ id: 'status-1' })).blocked).toBe(true);
    expect(resolveUserPostingStyle(style(), composer({ scheduled_status_id: 'sched-1' })).blocked).toBe(true);
  });

  it('applies a hashtag destination on a reply without replacing reply fields', () => {
    const hashtag = style({
      target: { kind: 'hashtag', accountId: null, hashtag: 'fedibird_info', label: '#fedibird_info' },
      defaults: { visibility: 'unlisted', language: { mode: 'explicit', code: 'en' } },
    });
    const plan = resolveUserPostingStyle(hashtag, composer({
      in_reply_to: 's1',
      text: '@reply_to 返信本文',
      privacy: 'private',
      language: 'ja',
    }));

    expect(plan.blocked).toBe(false);
    expect(plan.destination).toMatchObject({ action: 'hashtag', hashtag: 'fedibird_info', changes: false });
    expect(plan.fields.privacy).toBeUndefined();
    expect(plan.fields.language).toBeUndefined();
    expect(plan.unapplied).toEqual(expect.arrayContaining(['privacy', 'language']));
    expect(plan.unapplied).not.toContain('destination');
    expect(plan.needsConfirmation).toBe(false);
  });

  it('still skips a hashtag destination for a quote, a group reply, and a portable reply', () => {
    const hashtag = style({
      target: { kind: 'hashtag', accountId: null, hashtag: 'fedibird_info', label: '#fedibird_info' },
    });
    const quote = resolveUserPostingStyle(hashtag, composer({ quote_from: 'q1', text: 'Quote' }));
    const portable = resolveUserPostingStyle(hashtag, composer({
      in_reply_to: 's1',
      surface: { kind: 'hashtag', key: 'foo' },
      userPostingStyle: {
        manualFields: [],
        destinationSource: null,
        destinationStatus: 'idle',
        destinationAccountId: null,
        destinationPolicy: 'locked',
      },
    }));
    const group = resolveUserPostingStyle(style({
      target: { kind: 'group', accountId: '123', label: 'localsquad' },
    }), composer({ in_reply_to: 's1' }));

    expect(quote.destination.action).toEqual('skip');
    expect(quote.unapplied).toContain('destination');
    expect(portable.destination.action).toEqual('skip');
    expect(portable.unapplied).toContain('destination');
    expect(group.destination.action).toEqual('skip');
    expect(group.unapplied).toContain('destination');
    expect(group.needsConfirmation).toBe(false);
  });
});
