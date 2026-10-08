import { fromJS } from 'immutable';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

jest.mock('../../uuid', () => ({
  __esModule: true,
  default: () => 'test-idempotency-key',
}));

import { COMPOSE_UPLOAD_SUCCESS, COMPOSE_VISIBILITY_CHANGE, changeCompose } from '../../actions/compose';
import { applyComposerPostingContext } from '../../actions/composer';
import { USER_POSTING_STYLE_COMMIT, USER_POSTING_STYLE_HASHTAG_TOGGLE } from '../../actions/user_posting_styles';
import { materializeComposerText } from '../materialize';
import { nodebbGroupPostingContextFor } from '../fixtures/nodebb_group_context_fixture';
import { resolveUserPostingStyle } from '../user_style_resolver';
import composer from '../../reducers/composer';

const category = nodebbGroupPostingContextFor('456', 'category@nodebb.example');
const other = nodebbGroupPostingContextFor('789', 'other@nodebb.example');

const hashtagStyle = fromJS({
  id: '2',
  name: '読書メモ',
  revision: 1,
  target: { kind: 'hashtag', accountId: null, hashtag: 'books', label: '#books' },
  defaults: {},
  managed: {
    hashtags: [{ name: 'fedibird', normalizedName: 'fedibird', enforcement: 'advisory' }],
  },
});

const commitStyle = (state, style) => composer(state, {
  type: USER_POSTING_STYLE_COMMIT,
  plan: resolveUserPostingStyle(style, state),
  snapshot: style,
  resetSuppressions: true,
  restoreParked: false,
});

const applyContext = (state, context, accountId) => composer(
  state,
  applyComposerPostingContext('primary', context, accountId),
);

describe('NodeBB composer destination changes', () => {
  const drafted = () => {
    let state = composer(undefined, changeCompose('Keep this @category@nodebb.example'));

    state = composer(state, {
      type: COMPOSE_UPLOAD_SUCCESS,
      media: { id: 'media-1', type: 'image', description: 'tree' },
    });
    state = commitStyle(state, hashtagStyle);
    state = composer(state, {
      type: USER_POSTING_STYLE_HASHTAG_TOGGLE,
      origin: 'style',
      normalizedName: 'fedibird',
    });

    return state.set('idempotencyKey', 'previous-key');
  };

  it('does not add a required mention that is already in the draft', () => {
    const applied = applyContext(drafted(), category, '456');

    expect(applied.get('text')).toEqual('Keep this @category@nodebb.example');
    expect(materializeComposerText(applied)).toEqual('Keep this @category@nodebb.example\n\n#books');
    expect(materializeComposerText(applied).match(/@category@nodebb\.example/g)).toHaveLength(1);
  });

  it('keeps the draft, attachments, style tags, and suppressions while the group changes', () => {
    const start = drafted();
    const first = applyContext(start, category, '456');
    const same = applyContext(first.set('idempotencyKey', 'kept-key'), category, '456');
    const second = applyContext(same, other, '789');
    const usual = applyContext(second.set('idempotencyKey', 'kept-key'), null, null);

    expect(first.get('text')).toEqual('Keep this @category@nodebb.example');
    expect(first.get('media_attachments').size).toBe(1);
    expect(first.getIn(['media_attachments', 0, 'id'])).toEqual('media-1');
    expect(first.getIn(['context', 'protocol', 'activityPub', 'audience', 'accountId'])).toEqual('456');
    expect(first.getIn(['context', 'managed', 'mentions']).size).toBe(1);
    expect(first.getIn(['userPostingStyle', 'suppressions']).includes('style:fedibird')).toBe(true);
    expect(materializeComposerText(first)).toEqual('Keep this @category@nodebb.example\n\n#books');
    expect(materializeComposerText(first)).not.toContain('#fedibird');
    expect(first.get('idempotencyKey')).toEqual('test-idempotency-key');
    expect(same.get('idempotencyKey')).toEqual('kept-key');
    expect(same.get('text')).toEqual(first.get('text'));

    expect(second.get('text')).toEqual('Keep this @category@nodebb.example');
    expect(second.get('media_attachments')).toBe(first.get('media_attachments'));
    expect(second.getIn(['context', 'protocol', 'activityPub', 'audience', 'accountId'])).toEqual('789');
    expect(second.getIn(['context', 'key'])).toEqual('protocol:fep-1b12-nodebb:789');
    expect(second.getIn(['context', 'managed', 'mentions']).size).toBe(1);
    expect(second.getIn(['context', 'managed', 'mentions', 0, 'acct'])).toEqual('other@nodebb.example');
    expect(second.getIn(['userPostingStyle', 'suppressions']).includes('style:fedibird')).toBe(true);
    expect(materializeComposerText(second)).toEqual('@other@nodebb.example Keep this @category@nodebb.example\n\n#books');
    expect(materializeComposerText(second).match(/@other@nodebb\.example/g)).toHaveLength(1);
    expect(second.get('idempotencyKey')).toEqual('test-idempotency-key');

    expect(usual.get('text')).toEqual('Keep this @category@nodebb.example');
    expect(usual.get('media_attachments').size).toBe(1);
    expect(usual.get('posting_context_account_id')).toBeNull();
    expect(usual.getIn(['context', 'resolvedAccountId'])).toBeNull();
    expect(usual.getIn(['context', 'protocol', 'activityPub', 'audience'])).toBeNull();
    expect(usual.getIn(['context', 'managed', 'mentions']).size).toBe(0);
    expect(usual.getIn(['userPostingStyle', 'suppressions']).includes('style:fedibird')).toBe(true);
    expect(materializeComposerText(usual)).toEqual('Keep this @category@nodebb.example\n\n#books');
    expect(materializeComposerText(usual)).not.toContain('@other@nodebb.example');
    expect(usual.get('idempotencyKey')).toEqual('test-idempotency-key');
  });

  it('leaves unlisted in place when a NodeBB context only allows public', () => {
    const unlisted = composer(drafted(), { type: COMPOSE_VISIBILITY_CHANGE, value: 'unlisted' });
    const applied = applyContext(unlisted, category, '456');

    expect(applied.get('privacy')).toEqual('unlisted');
    expect(applied.getIn(['context', 'constraints', 'allowedVisibilities']).toArray()).toEqual(['public']);
    expect(applied.get('text')).toEqual('Keep this @category@nodebb.example');
    expect(applied.get('media_attachments').size).toBe(1);
  });
});
