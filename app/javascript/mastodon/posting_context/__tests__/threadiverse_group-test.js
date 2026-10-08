import { fromJS } from 'immutable';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

jest.mock('../../uuid', () => ({
  __esModule: true,
  default: () => 'test-idempotency-key',
}));

import { COMPOSE_UPLOAD_SUCCESS, changeCompose } from '../../actions/compose';
import { applyComposerPostingContext } from '../../actions/composer';
import { USER_POSTING_STYLE_COMMIT } from '../../actions/user_posting_styles';
import { lemmyGroupPostingContextFor } from '../fixtures/threadiverse_group_context_fixture';
import { materializeComposerText, postingContextOutputSignature } from '../materialize';
import { resolveUserPostingStyle } from '../user_style_resolver';
import composer from '../../reducers/composer';

const technology = lemmyGroupPostingContextFor('456', 'technology@lemmy.example');
const other = lemmyGroupPostingContextFor('789', 'other@lemmy.example');
const prepended = {
  ...technology,
  managed: {
    ...technology.managed,
    mentions: [{ ...technology.managed.mentions[0], placement: 'prepend' }],
  },
};

const booksStyle = fromJS({
  id: '2',
  name: '読書メモ',
  revision: 1,
  target: { kind: 'hashtag', accountId: null, hashtag: 'books', label: '#books' },
  defaults: {},
  managed: {
    hashtags: [{ name: 'fedibird', normalizedName: 'fedibird', enforcement: 'advisory' }],
  },
});

const applyContext = (state, context, accountId) => composer(
  state,
  applyComposerPostingContext('primary', context, accountId),
);

describe('Lemmy and PieFed composer mentions', () => {
  const drafted = () => {
    let state = composer(undefined, changeCompose('Title line\n\nKeep this @bob@people.example'));

    state = composer(state, {
      type: COMPOSE_UPLOAD_SUCCESS,
      media: { id: 'media-1', type: 'image', description: 'tree' },
    });
    state = composer(state, {
      type: USER_POSTING_STYLE_COMMIT,
      plan: resolveUserPostingStyle(booksStyle, state),
      snapshot: booksStyle,
      resetSuppressions: true,
      restoreParked: false,
    });

    return state.set('idempotencyKey', 'previous-key');
  };

  it('appends the community mention after the draft and style hashtags', () => {
    const applied = applyContext(drafted(), technology, '456');
    const sent = materializeComposerText(applied);

    expect(applied.get('text')).toEqual('Title line\n\nKeep this @bob@people.example');
    expect(sent.split('\n')[0]).toEqual('Title line');
    expect(sent).toEqual('Title line\n\nKeep this @bob@people.example\n@technology@lemmy.example\n\n#fedibird #books');
    expect(sent.match(/@technology@lemmy\.example/g)).toHaveLength(1);
    expect(sent.indexOf('@bob@people.example')).toBeLessThan(sent.indexOf('@technology@lemmy.example'));
    expect(sent.indexOf('@technology@lemmy.example')).toBeLessThan(sent.indexOf('#books'));
  });

  it('does not mix automatic mentions when the destination changes', () => {
    const first = applyContext(drafted(), technology, '456');
    const second = applyContext(first.set('idempotencyKey', 'kept-key'), other, '789');
    const usual = applyContext(second.set('idempotencyKey', 'kept-key'), null, null);

    expect(materializeComposerText(second)).toEqual('Title line\n\nKeep this @bob@people.example\n@other@lemmy.example\n\n#fedibird #books');
    expect(materializeComposerText(second)).not.toContain('@technology@lemmy.example');
    expect(second.get('text')).toEqual(first.get('text'));
    expect(second.getIn(['media_attachments', 0, 'id'])).toEqual('media-1');
    expect(second.getIn(['context', 'managed', 'mentions']).size).toBe(1);
    expect(second.get('idempotencyKey')).toEqual('test-idempotency-key');

    expect(usual.get('text')).toEqual('Title line\n\nKeep this @bob@people.example');
    expect(usual.getIn(['media_attachments']).size).toBe(1);
    expect(materializeComposerText(usual)).toEqual('Title line\n\nKeep this @bob@people.example\n\n#fedibird #books');
    expect(materializeComposerText(usual)).not.toContain('@other@lemmy.example');
    expect(usual.getIn(['context', 'protocol', 'activityPub', 'audience'])).toBeNull();
  });

  it('rotates the idempotency key when only mention placement changes', () => {
    const appended = applyContext(drafted(), technology, '456');
    const moved = applyContext(appended.set('idempotencyKey', 'kept-key'), prepended, '456');

    expect(appended.getIn(['context', 'managed', 'mentions', 0, 'placement'])).toEqual('append');
    expect(postingContextOutputSignature(appended)).not.toEqual(postingContextOutputSignature(moved));
    expect(materializeComposerText(moved).startsWith('@technology@lemmy.example ')).toBe(true);
    expect(moved.get('idempotencyKey')).toEqual('test-idempotency-key');
    expect(moved.get('text')).toEqual(appended.get('text'));
  });

  it('does not materialize a mention while editing an existing post', () => {
    const editing = drafted().set('id', 'status-1');
    const applied = applyContext(editing, technology, '456');

    expect(materializeComposerText(applied)).toEqual('Title line\n\nKeep this @bob@people.example');
  });
});
