jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

import { Map as ImmutableMap, fromJS } from 'immutable';

import { STORE_HYDRATE } from '../../actions/store';
import settings from '../../reducers/settings';
import {
  PORTABLE_COMPOSER_MODE_FULL,
  PORTABLE_COMPOSER_MODE_SIMPLE,
  selectPortableComposerDisplayMode,
} from '../composer';

describe('portable composer display mode', () => {
  it('keeps each composer id independent and treats missing or unknown values as full', () => {
    let state = settings(undefined, { type: '@@INIT' });

    expect(state.get('portableComposerDisplayMode')).toEqual(ImmutableMap());

    state = settings(state, {
      type: STORE_HYDRATE,
      state: fromJS({
        settings: {
          portableComposerDisplayMode: {
            'portable:list-column:a': 'simple',
            'portable:list-column:b': 'full',
            'portable:hashtag-column:ruby': 'simple',
            'portable:group-column:g': 'full',
          },
          portableComposerVisibility: {
            'portable:list-column:a': false,
          },
        },
      }),
    });
    state = settings(state, {
      type: 'SETTING_CHANGE',
      path: ['portableComposerDisplayMode', 'portable:group-route:9'],
      value: 'nope',
    });
    state = settings(state, {
      type: 'SETTING_CHANGE',
      path: ['portableComposerDisplayMode', 'portable:hashtag-route:news'],
      value: null,
    });

    const root = ImmutableMap({ settings: state });

    expect(selectPortableComposerDisplayMode(root, 'portable:list-column:a')).toBe(PORTABLE_COMPOSER_MODE_SIMPLE);
    expect(selectPortableComposerDisplayMode(root, 'portable:list-column:b')).toBe(PORTABLE_COMPOSER_MODE_FULL);
    expect(selectPortableComposerDisplayMode(root, 'portable:hashtag-column:ruby')).toBe(PORTABLE_COMPOSER_MODE_SIMPLE);
    expect(selectPortableComposerDisplayMode(root, 'portable:group-column:g')).toBe(PORTABLE_COMPOSER_MODE_FULL);
    expect(selectPortableComposerDisplayMode(root, 'portable:group-route:9')).toBe(PORTABLE_COMPOSER_MODE_FULL);
    expect(selectPortableComposerDisplayMode(root, 'portable:hashtag-route:news')).toBe(PORTABLE_COMPOSER_MODE_FULL);
    expect(selectPortableComposerDisplayMode(root, 'portable:list-route:missing')).toBe(PORTABLE_COMPOSER_MODE_FULL);
    expect(state.getIn(['portableComposerVisibility', 'portable:list-column:a'])).toBe(false);
    expect(state.getIn(['portableComposerDisplayMode', 'portable:list-column:a'])).toBe('simple');
    expect(state.getIn(['portableComposerDisplayMode', 'portable:list-column:b'])).toBe('full');
  });
});
