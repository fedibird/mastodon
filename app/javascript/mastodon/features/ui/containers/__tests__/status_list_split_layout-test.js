import { fromJS, List as ImmutableList } from 'immutable';

import { makeMapStateToProps } from '../status_list_container';

const splitId = 'list:42:split:column-a:session';
const timelineId = 'list:42';

const buildState = (layoutMode = 'normal') => {
  const statuses = {};
  const ids = [];

  for (let n = 65; n >= 1; n--) {
    const id = String(n);
    ids.push(id);
    statuses[id] = {
      account: 'remote',
      visibility: 'public',
      reblog: null,
      in_reply_to_id: null,
      in_reply_to_account_id: null,
      media_attachments: [],
    };
  }

  statuses['20'].reblog = '2';
  statuses['2'].media_attachments = [{ id: 'video', type: 'video' }];
  statuses['3'].media_attachments = [{ id: 'image', type: 'image' }];

  return fromJS({
    settings: {
      list: { layoutMode: 'card-1' },
      columns: [{ uuid: 'pinned-list', params: { layoutMode } }],
    },
    timelines: {
      [timelineId]: { pendingItems: [], items: ids },
      [splitId]: { pendingItems: [], items: ids },
    },
    statuses,
  });
};

const liveProps = {
  layoutScope: 'list',
  columnId: 'pinned-list',
  timelineId,
  dataTimelineId: timelineId,
  includePendingItems: true,
  statusLimit: 40,
};

const historyProps = {
  layoutScope: 'list',
  columnId: 'pinned-list',
  timelineId,
  dataTimelineId: splitId,
};

describe('split timeline layout selection', () => {
  it.each(['normal', 'card-1', 'card-2', 'card-3', 'media'])(
    'passes %s to both Live and History without changing their data identities',
    mode => {
      const select = makeMapStateToProps();
      const state = buildState(mode);
      const live = select(state, liveProps);
      const history = select(state, historyProps);

      expect(live.layoutMode).toBe(mode);
      expect(history.layoutMode).toBe(mode);
      expect(live.mediaStatuses !== null).toBe(mode === 'media');
      expect(history.mediaStatuses !== null).toBe(mode === 'media');
      expect(history.statusIds).toEqual(ImmutableList(
        Array.from({ length: 65 }, (_, index) => String(65 - index)),
      ));
    },
  );

  it('keeps pinned and standalone column settings separate, including after changes', () => {
    const select = makeMapStateToProps();
    const original = buildState('card-3');
    const standalone = { ...historyProps, columnId: undefined };

    expect(select(original, historyProps).layoutMode).toBe('card-3');
    expect(select(original, standalone).layoutMode).toBe('card-1');

    const changed = original.setIn(['settings', 'columns', 0, 'params', 'layoutMode'], 'card-2');

    expect(select(changed, liveProps).layoutMode).toBe('card-2');
    expect(select(changed, historyProps).layoutMode).toBe('card-2');
    expect(select(changed, standalone).layoutMode).toBe('card-1');
    expect(select(changed, { ...historyProps, disableLayout: true }).layoutMode).toBe('normal');
  });

  it('selects media-bearing Live posts before applying the 40-post cap', () => {
    const select = makeMapStateToProps();
    const state = buildState('media');
    const live = select(state, liveProps);
    const history = select(state, historyProps);

    // Only status 3, status 2 and the reblog at 20 have media among the 65
    // loaded posts. All three are older than the most recent 40 status IDs.
    expect(live.statusIds.toArray()).toEqual(['20', '3', '2']);
    expect(live.filterStatusIds.size).toBe(65);
    expect(history.statusIds.size).toBe(65);
  });

  it('does not change the conventional 40-post Live cap in normal mode', () => {
    const select = makeMapStateToProps();
    const live = select(buildState('normal'), liveProps);

    expect(live.statusIds.size).toBe(40);
    expect(live.statusIds.first()).toBe('65');
    expect(live.statusIds.last()).toBe('26');
  });
});
