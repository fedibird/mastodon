import React from 'react';
import Immutable from 'immutable';
import { fireEvent, render } from '@testing-library/react';
import Card from '../card';

jest.mock('mastodon/initial_state', () => ({ useBlurhash: false }));
jest.mock('react-intl', () => ({ FormattedMessage: () => null }));
jest.mock('mastodon/components/blurhash', () => () => null);
jest.mock('mastodon/components/thumbhash', () => () => null);
jest.mock('mastodon/components/icon', () => () => null);

// Synthetic REST card, not a captured YouTube response. No external requests.
const makeCard = (overrides = {}) => Immutable.fromJS({
  type: 'video',
  url: 'https://www.youtube.com/shorts/abcdefghijk',
  title: 'Embed diagnostic fixture',
  description: '',
  provider_name: 'YouTube',
  width: 200,
  height: 113,
  html: '<iframe width="200" height="113" src="https://www.youtube.com/embed/abcdefghijk?feature=oembed" frameborder="0" allowfullscreen sandbox="allow-scripts allow-same-origin allow-popups allow-popups-to-escape-sandbox allow-forms"></iframe>',
  ...overrides,
});

describe('video card insertion (issue #473)', () => {
  beforeEach(() => {
    jest.spyOn(HTMLElement.prototype, 'offsetWidth', 'get').mockReturnValue(320);
  });

  afterEach(() => {
    jest.restoreAllMocks();
  });

  const embed = card => {
    const view = render(<Card card={card} onOpenMedia={jest.fn()} />);
    expect(view.container.querySelector('iframe')).toBeNull();
    fireEvent.click(view.container.querySelector('.status-card__actions button'));
    return view;
  };

  it('uses the same embed for Shorts and watch cards with the same REST payload', () => {
    const shorts = embed(makeCard());
    const shortsHTML = shorts.container.querySelector('iframe').outerHTML;
    const shortsHeight = shorts.container.querySelector('.status-card-video').style.height;
    shorts.unmount();

    const watch = embed(makeCard({ url: 'https://www.youtube.com/watch?v=abcdefghijk' }));
    expect(watch.container.querySelector('iframe').outerHTML).toBe(shortsHTML);
    expect(watch.container.querySelector('.status-card-video').style.height).toBe(shortsHeight);
  });

  it.each(['', '?feature=oembed'])('preserves the embed target and query when appending autoplay to %s', query => {
    const view = embed(makeCard({ html: `<iframe src="https://www.youtube.com/embed/abcdefghijk${query}"></iframe>` }));
    const url = new URL(view.container.querySelector('iframe').src);
    expect(url.origin).toBe('https://www.youtube.com');
    expect(url.pathname).toBe('/embed/abcdefghijk');
    expect(url.searchParams.get('autoplay')).toBe('1');
    expect(url.searchParams.get('auto_play')).toBe('1');
    expect(url.searchParams.get('feature')).toBe(query ? 'oembed' : null);
  });

  it('preserves the sandbox and fullscreen attributes from the REST payload', () => {
    const view = embed(makeCard());
    const iframe = view.container.querySelector('iframe');
    expect(iframe.getAttribute('sandbox')).toBe('allow-scripts allow-same-origin allow-popups allow-popups-to-escape-sandbox allow-forms');
    expect(iframe.hasAttribute('allowfullscreen')).toBe(true);
    expect(iframe.getAttribute('width')).toBe('200');
    expect(iframe.getAttribute('height')).toBe('113');
  });

  it.each([[200, 113], [113, 200]])('computes the wrapper height from %s x %s metadata', (width, height) => {
    const view = embed(makeCard({ width, height }));
    expect(parseFloat(view.container.querySelector('.status-card-video').style.height)).toBeCloseTo(320 * height / width);
  });
});
