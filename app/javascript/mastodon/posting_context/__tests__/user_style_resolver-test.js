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
});
