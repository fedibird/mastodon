jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

import { fromJS } from 'immutable';

import { COMPOSE_REPLY, COMPOSE_SET_STATUS, COMPOSE_VISIBILITY_CHANGE } from '../../actions/compose';
import { REDRAFT } from '../../actions/statuses';
import { normalizeStatus } from '../../actions/importer/normalizer';
import composer from '../../reducers/composer';
import { canEditStatus } from '../status_edit';
import { COMPOSER_PRIVACIES, composerPrivacy } from '../external_visibility';

describe('external visibility', () => {
  it('is not a composer choice and does not replace a saved privacy', () => {
    expect(COMPOSER_PRIVACIES).not.toContain('external');
    expect(composerPrivacy('external', 'private')).toBe('private');
    expect(composerPrivacy('external', 'nope')).toBe('public');
    expect(composerPrivacy('personal', 'public')).toBe('personal');
  });

  it('cannot be edited', () => {
    const external = fromJS({ visibility: 'external', account: { id: '1', acct: 'me' } });
    const personal = fromJS({ visibility: 'personal', account: { id: '1', acct: 'me' } });

    expect(canEditStatus(external, { me: '1' })).toBe(false);
    expect(canEditStatus(personal, { me: '1' })).toBe(true);
  });

  it('normalizes visibility_ex without putting external on the wire visibility', () => {
    const normalized = normalizeStatus({
      id: '9',
      content: '<p>External owner article</p>',
      spoiler_text: '',
      visibility: 'direct',
      visibility_ex: 'external',
      sensitive: false,
      media_attachments: [],
      mentions: [],
      tags: [],
      emojis: [],
      account: '1',
    });

    expect(normalized.visibility).toBe('external');
    expect(normalized.visibility_ex).toBe('external');
  });

  it('does not copy external into reply, redraft, or edit privacy', () => {
    const state = composer(undefined, { type: '@@INIT' }).set('default_privacy', 'private');
    const status = fromJS({
      id: '9',
      text: 'secret',
      content: '<p>secret</p>',
      visibility: 'external',
      searchability: 'personal',
      spoiler_text: '',
      media_attachments: [],
      mentions: [],
      account: { id: '1', acct: 'me' },
    });

    const replied = composer(state, { type: COMPOSE_REPLY, status });
    expect(replied.get('privacy')).toBe('private');

    const draft = state.set('text', 'kept draft').set('privacy', 'unlisted');
    const redrafted = composer(draft, {
      type: REDRAFT,
      raw_text: 'secret',
      status: status.set('media_attachments', fromJS([{ id: 'media-1', type: 'image' }])),
      context_references: fromJS([]),
    });
    expect(redrafted.get('privacy')).toBe('unlisted');
    expect(redrafted.get('text')).toBe('kept draft');
    expect(redrafted.get('media_attachments')).toEqual(draft.get('media_attachments'));

    const edited = composer(state, {
      type: COMPOSE_SET_STATUS,
      status,
      text: 'secret',
      spoiler_text: '',
    });
    expect(edited.get('privacy')).toBe('private');

    const unchanged = composer(state.set('privacy', 'unlisted'), { type: COMPOSE_VISIBILITY_CHANGE, value: 'external' });
    expect(unchanged.get('privacy')).toBe('unlisted');
  });
});
