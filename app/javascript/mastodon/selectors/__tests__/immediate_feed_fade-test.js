jest.mock('mastodon/initial_state', () => ({
  new_features_policy: 'tester',
}));

import { fromJS, List as ImmutableList, Map as ImmutableMap } from 'immutable';
import { immediateFeedPresentationFrom, immediateFeedUsesFade } from '../immediate_feed';

describe('tester immediate fade', () => {
  it('fades only while the entry is immediate', () => {
    expect(immediateFeedUsesFade()).toBe(true);
    expect(immediateFeedUsesFade('conservative')).toBe(false);
    expect(immediateFeedUsesFade('default')).toBe(false);

    const immediate = fromJS({
      entries: {
        'portable:hashtag-column:news\u000077': {
          statusId: '77',
          viewKey: 'portable:hashtag-column:news',
          timelineId: 'hashtag:news',
          phase: 'immediate',
          generation: 1,
        },
        'portable:hashtag-column:news\u000088': {
          statusId: '88',
          viewKey: 'portable:hashtag-column:news',
          timelineId: 'hashtag:news',
          phase: 'expired',
          generation: 2,
        },
      },
    });
    const timeline = ImmutableMap({
      items: ImmutableList(['77']),
      pendingItems: ImmutableList(),
      top: true,
    });
    const presentation = immediateFeedPresentationFrom(immediate, timeline, {
      viewKey: 'portable:hashtag-column:news',
      timelineId: 'hashtag:news',
      dataTimelineId: 'hashtag:news',
      includePendingItems: false,
    });

    expect(presentation.get('fadeIds').toArray()).toEqual(['77']);
    expect(presentation.get('prependIds').toArray()).toEqual(['88']);
  });
});