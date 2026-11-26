import React from 'react';

import { act, render } from '@testing-library/react';
import { Map as ImmutableMap } from 'immutable';
import { createStore } from 'redux';

import { EMOJI_MUTES_ENABLE, EMOJI_MUTES_IGNORE } from 'mastodon/actions/emoji_mutes';
import Column from 'mastodon/components/column';
import { createUnverifiedEmojiGuard } from 'mastodon/features/emoji/emoji_mute_live_dom';
import emojiMutes from 'mastodon/reducers/emoji_mutes';

const THUMB = '\u{1F44D}';
const PLACEHOLDER = '\u25FB';

const label = `List ${THUMB}`;

const reducer = (state = ImmutableMap(), action) => state.set('emojiMutes', emojiMutes(state.get('emojiMutes'), action));

describe('Column landmark writes', () => {
  beforeEach(() => {
    document.body.innerHTML = '';
  });

  it('does not restore a suppressed label when an ordinary column updates', () => {
    const store = createStore(reducer);
    const container = document.createElement('div');
    container.className = 'emoji-mutes-privacy-portal';
    document.body.appendChild(container);
    const mount = document.createElement('div');
    container.appendChild(mount);

    const guard = createUnverifiedEmojiGuard(store);
    store.subscribe(() => guard(store.getState()));

    const view = render(
      <Column label={label} columnWidth='one'><span>a</span></Column>,
      { container: mount },
    );

    const region = () => container.querySelector('[role="region"]');

    expect(region().getAttribute('aria-label')).toBe(label);

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_ENABLE });
    });

    expect(region().getAttribute('aria-label')).toBe(`List ${PLACEHOLDER}`);
    expect(region().getAttribute('aria-label')).not.toContain(THUMB);

    view.rerender(
      <Column label={label} columnWidth='two'><span>b</span></Column>,
    );

    expect(region().getAttribute('aria-label')).toBe(`List ${PLACEHOLDER}`);
    expect(region().textContent).toBe('b');

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_IGNORE });
    });

    expect(region().getAttribute('aria-label')).toBe(label);
  });
});
