jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

import { Map as ImmutableMap } from 'immutable';

import settings from '../../reducers/settings';
import { selectPortableComposerVisible } from '../composer';

describe('portable composer visibility', () => {
  it('stores each composer id independently and treats missing values as hidden', () => {
    let state = settings(undefined, { type: '@@INIT' });

    expect(state.get('portableComposerVisibility')).toEqual(ImmutableMap());

    state = settings(state, {
      type: 'SETTING_CHANGE',
      path: ['portableComposerVisibility', 'portable:list-column:a'],
      value: true,
    });
    state = settings(state, {
      type: 'SETTING_CHANGE',
      path: ['portableComposerVisibility', 'portable:list-column:b'],
      value: false,
    });
    state = settings(state, {
      type: 'SETTING_CHANGE',
      path: ['portableComposerVisibility', 'portable:hashtag-route:ruby'],
      value: true,
    });
    state = settings(state, {
      type: 'SETTING_CHANGE',
      path: ['portableComposerVisibility', 'portable:group-route:9'],
      value: null,
    });

    const root = ImmutableMap({ settings: state });

    expect(selectPortableComposerVisible(root, 'portable:list-column:a')).toBe(true);
    expect(selectPortableComposerVisible(root, 'portable:list-column:b')).toBe(false);
    expect(selectPortableComposerVisible(root, 'portable:hashtag-route:ruby')).toBe(true);
    expect(selectPortableComposerVisible(root, 'portable:group-route:9')).toBe(false);
    expect(selectPortableComposerVisible(root, 'portable:group-column:missing')).toBe(false);
    expect(state.getIn(['portableComposerVisibility', 'portable:list-column:a'])).toBe(true);
    expect(state.getIn(['portableComposerVisibility', 'portable:list-column:b'])).toBe(false);
  });
});
