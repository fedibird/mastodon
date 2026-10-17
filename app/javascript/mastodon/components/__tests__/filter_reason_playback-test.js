import { render, screen } from '@testing-library/react';
import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
import React from 'react';

jest.mock('mastodon/initial_state', () => ({
  autoPlayEmoji: true,
}));

import { FilterReason } from '../filter_reason';

describe('FilterReason animation setting', () => {
  it('uses the animated image when autoPlayEmoji is enabled', () => {
    render(
      <FilterReason
        titles={[':known:']}
        customEmojis={ImmutableList([
          ImmutableMap({
            shortcode: 'known',
            url: 'https://cdn.example.test/known.gif',
            static_url: 'https://cdn.example.test/known.png',
          }),
        ])}
      />,
    );

    const image = screen.getByRole('img', { name: ':known:' });

    expect(image).toHaveAttribute('src', 'https://cdn.example.test/known.gif');
    expect(image).toHaveAttribute('data-original', 'https://cdn.example.test/known.gif');
    expect(image).toHaveAttribute('data-static', 'https://cdn.example.test/known.png');
  });
});
