import { fromJS, Map as ImmutableMap, List as ImmutableList } from 'immutable';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

import { changeComposeSearchability, resetComposeSearchability } from '../../actions/compose';
import { createComposer, targetComposerAction } from '../../actions/composer';
import composer from '../../reducers/composer';
import composers from '../../reducers/composers';
import { commitUserPostingStyle, reapplySelectedStyle } from '../user_style_state';
import { resolveUserPostingStyle } from '../user_style_resolver';

const style = fromJS({
  id: 'style-1',
  name: '公開メモ',
  revision: 1,
  target: { kind: 'none', accountId: null, hashtag: null, label: null },
  defaults: { visibility: 'unlisted' },
  managed: { hashtags: [] },
});

const widened = () => {
  let state = composer(undefined, { type: '@@INIT' });

  state = state.set('privacy', 'private').set('searchability', 'private');
  state = composer(state, changeComposeSearchability('public'));

  return state;
};

const commit = state => {
  const plan = resolveUserPostingStyle(style, state, { destinationPolicy: 'change' });

  return commitUserPostingStyle(state, {
    plan,
    snapshot: style,
    resetSuppressions: true,
    selectionOrigin: 'manual',
  });
};

describe('posting style clears searchability privacy restore', () => {
  it('does not restore the pre-searchability privacy after a style changes privacy', () => {
    let state = commit(widened());

    expect(state.get('privacy')).toBe('unlisted');
    expect(state.get('privacy_before_searchability')).toBeNull();

    state = composer(state, resetComposeSearchability());

    expect(state.get('privacy')).toBe('unlisted');
    expect(state.get('searchability')).toBe('private');
  });

  it('drops the restore point again when the selected style is reapplied', () => {
    let state = commit(widened());

    state = composer(state, changeComposeSearchability('public'));
    expect(state.get('privacy')).toBe('public');
    expect(state.get('privacy_before_searchability')).toBe('unlisted');

    state = reapplySelectedStyle(state, { respectManual: false, resetSuppressions: false });

    expect(state.get('privacy')).toBe('unlisted');
    expect(state.get('privacy_before_searchability')).toBeNull();

    state = composer(state, resetComposeSearchability());

    expect(state.get('privacy')).toBe('unlisted');
  });

  it('keeps a visibility chosen by hand after the style is applied', () => {
    let state = commit(widened());

    state = composer(state, { type: 'COMPOSE_VISIBILITY_CHANGE', value: 'limited' });
    state = composer(state, resetComposeSearchability());

    expect(state.get('privacy')).toBe('limited');
    expect(state.get('privacy_before_searchability')).toBeNull();
  });

  it('does not clear the restore point on another composer', () => {
    let registry = composers(undefined, { type: '@@INIT' });

    registry = composers(registry, createComposer('composer-a'));
    registry = composers(registry, createComposer('composer-b'));
    registry = registry.setIn(['byId', 'composer-a', 'privacy'], 'private').setIn(['byId', 'composer-a', 'searchability'], 'private');
    registry = registry.setIn(['byId', 'composer-b', 'privacy'], 'private').setIn(['byId', 'composer-b', 'searchability'], 'private');
    registry = composers(registry, targetComposerAction(changeComposeSearchability('public'), 'composer-a'));
    registry = composers(registry, targetComposerAction(changeComposeSearchability('public'), 'composer-b'));

    const plan = resolveUserPostingStyle(style, registry.getIn(['byId', 'composer-a']), { destinationPolicy: 'change' });

    registry = composers(registry, targetComposerAction({
      type: 'USER_POSTING_STYLE_COMMIT',
      plan,
      snapshot: style,
      resetSuppressions: true,
      selectionOrigin: 'manual',
    }, 'composer-a'));

    expect(registry.getIn(['byId', 'composer-a', 'privacy'])).toBe('unlisted');
    expect(registry.getIn(['byId', 'composer-a', 'privacy_before_searchability'])).toBeNull();
    expect(registry.getIn(['byId', 'composer-b', 'privacy'])).toBe('public');
    expect(registry.getIn(['byId', 'composer-b', 'privacy_before_searchability'])).toBe('private');
    expect(ImmutableMap.isMap(registry.getIn(['byId', 'composer-b']))).toBe(true);
    expect(ImmutableList.isList(style.getIn(['managed', 'hashtags']))).toBe(true);
  });
});
