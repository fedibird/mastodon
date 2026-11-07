import { fromJS } from 'immutable';
import {
  fullscreenFlowColumns,
  fullscreenScaleFactor,
  initialFullscreenPresentation,
  layoutModeForPresentation,
  presentationFromLayoutMode,
} from '../fullscreen_column';
import { resolveFullscreenSource } from '../../features/fullscreen_column/sources';
import fullscreenColumn from '../../reducers/fullscreen_column';
import { closeFullscreenColumn, openFullscreenColumn, patchFullscreenColumn } from '../../actions/fullscreen_column';
import { claimEscape, registerOverlayLayer, resetOverlayLayersForTests, topOverlayLayer } from '../overlay_layers';
import { makeMapStateToProps } from '../../features/ui/containers/status_list_container';

jest.mock('mastodon/components/status_list', () => function StatusListMock () {
  return null;
});

const settingsState = (extra = {}) => fromJS({
  meta: { layout: 'multi-column' },
  settings: {
    home: { layoutMode: 'card-2', shows: { private: true, limited: true, direct: true, personal: true } },
    columns: [
      { uuid: 'home-col', id: 'HOME', params: { layoutMode: 'normal' } },
      { uuid: 'fav-col', id: 'FAVOURITES', params: { layoutMode: 'media', other: { onlyMedia: true } } },
    ],
    favourited_statuses: { layoutMode: 'normal', other: { onlyMedia: false, withoutMedia: false } },
    public: { layoutMode: 'normal', other: { onlyRemote: true, onlyMedia: false, withoutMedia: false, withoutBot: false } },
    ...extra,
  },
  externalFeeds: { permitted: false },
});

describe('fullscreen presentation', () => {
  it('keeps scale independent from the requested column count', () => {
    expect(fullscreenScaleFactor('small')).toBe(1);
    expect(fullscreenScaleFactor('medium')).toBe(1.25);
    expect(fullscreenScaleFactor('large')).toBe(1.5);
    expect(fullscreenScaleFactor('max')).toBe(2);
    expect(fullscreenFlowColumns(3, 2100, 'max')).toBe(3);
    expect(fullscreenFlowColumns(3, 1400, 'max')).toBe(2);
    expect(presentationFromLayoutMode('card-3')).toEqual({ appearance: 'card', columns: 3 });
    expect(layoutModeForPresentation({ appearance: 'normal', columns: 3 })).toBe('normal');
    expect(layoutModeForPresentation({ appearance: 'card', columns: 2 })).toBe('card-2');
    expect(initialFullscreenPresentation('media').appearance).toBe('media');
  });
});

describe('fullscreen source identity', () => {
  it('uses the pinned column layout and does not give favourites a second list key', () => {
    const state = settingsState();
    const home = resolveFullscreenSource(state, { layoutScope: 'home', columnId: 'home-col', pathname: '/' });
    const favourites = resolveFullscreenSource(state, { layoutScope: 'favourited_statuses', columnId: 'fav-col', pathname: '/favourites' });
    const publicTimeline = resolveFullscreenSource(state, { layoutScope: 'public', pathname: '/timelines/public' });

    expect(home.dataTimelineId).toBe('home');
    expect(home.layoutMode).toBe('normal');
    expect(favourites.listKey).toBe('favourites');
    expect(favourites.expand).toBe('favourites');
    expect(favourites.dataTimelineId).toBeNull();
    expect(publicTimeline.dataTimelineId).toBe('public:remote:bot');
  });

  it('refuses to open from a mobile layout and does not rewrite settings', () => {
    const state = settingsState().setIn(['meta', 'layout'], 'mobile');
    const actions = [];
    const viewId = openFullscreenColumn({ layoutScope: 'home' })(
      (action) => actions.push(action),
      () => state,
    );

    expect(viewId).toBeNull();
    expect(actions).toEqual([]);
  });
});

describe('fullscreen column reducer', () => {
  it('keeps presentation changes on the fullscreen session', () => {
    let state = fullscreenColumn(null, {
      type: 'FULLSCREEN_COLUMN_OPEN',
      viewId: 'fsview:1',
      composerId: 'fullscreen:home:route',
      source: { kind: 'timeline', sourceKey: 'home:route', listKey: null },
      presentation: initialFullscreenPresentation('normal'),
      anchorStatusId: '10',
    });

    state = fullscreenColumn(state, patchFullscreenColumn({ presentation: state.get('presentation').set('columns', 3).set('scale', 'max') }));
    expect(state.getIn(['presentation', 'columns'])).toBe(3);
    expect(state.getIn(['presentation', 'scale'])).toBe('max');
    expect(state.get('anchorStatusId')).toBe('10');
    state = fullscreenColumn(state, closeFullscreenColumn());
    expect(state).toBeNull();
  });
});

describe('overlay escape stack', () => {
  afterEach(() => {
    resetOverlayLayersForTests();
  });

  it('closes only the top layer and ignores a claimed menu escape', () => {
    const closed = [];

    registerOverlayLayer({ id: 'fullscreen-column', priority: 20, onEscape: () => closed.push('column') });
    registerOverlayLayer({ id: 'fullscreen-composer', priority: 60, onEscape: () => closed.push('composer') });
    registerOverlayLayer({ id: 'modal-root', priority: 80, onEscape: () => closed.push('modal') });
    expect(topOverlayLayer().id).toBe('modal-root');

    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));
    claimEscape();
    window.dispatchEvent(new KeyboardEvent('keyup', { key: 'Escape' }));
    expect(closed).toEqual([]);

    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));
    window.dispatchEvent(new KeyboardEvent('keyup', { key: 'Escape' }));
    expect(closed).toEqual(['modal']);
  });
});

describe('passive fullscreen status list', () => {
  it('uses the override layout and does not claim history ownership', () => {
    const select = makeMapStateToProps();
    const state = fromJS({
      settings: {
        home: { layoutMode: 'card-3', shows: {} },
        columns: [],
      },
      timelines: {
        home: {
          items: ['1'],
          pendingItems: [],
          isLoading: false,
          hasMore: true,
          window: { hasNewer: true, revision: 2, newer: { status: 'idle' }, older: { status: 'idle' } },
        },
      },
      statuses: {
        1: { account: 'me', visibility: 'public', reblog: null, in_reply_to_id: null, in_reply_to_account_id: null, media_attachments: [] },
      },
    });
    const props = select(state, {
      timelineId: 'home',
      layoutScope: 'home',
      presentationOverride: true,
      layoutMode: 'normal',
      passiveView: true,
    });

    expect(props.layoutMode).toBe('normal');
    expect(props.historySurfaceId).toBeNull();
    expect(props.windowedHistory).toBe(false);
    expect(select(state, { timelineId: 'home', layoutScope: 'home' }).layoutMode).toBe('card-3');
  });
});
