import React from 'react';
import { fromJS } from 'immutable';
import {
  fullscreenFlowColumns,
  fullscreenScaleFactor,
  initialFullscreenPresentation,
  layoutModeForPresentation,
  presentationFromLayoutMode,
} from '../fullscreen_column';
import { resolveFullscreenSource, stripRouterBasename } from '../../features/fullscreen_column/sources';
import { createOverlayHistory, createOverlayHref, FullscreenRouter, fullscreenLayerDepth } from '../../features/fullscreen_column/overlay_history';
import { capturedComposerDestination, closeFullscreenColumn, dispatchFullscreenCompose, openFullscreenColumn, patchFullscreenColumn } from '../../actions/fullscreen_column';
import { restoreFilterAnchor } from '../../filter_reconciliation/scroll_anchor';
import { render } from '@testing-library/react';
import { Link, NavLink, Router } from 'react-router-dom';
import { createMemoryHistory } from 'history';
import { nodesInActiveLayer } from '../overlay_portal';
import { scrollTopDeltaForVisualDelta } from '../css_zoom';
import { articleFocusTarget } from '../article_focus';
import { mixExtendSwitchesToHistory } from '../../actions/mix_timelines';
import fullscreenColumn from '../../reducers/fullscreen_column';
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

describe('fullscreen routes keep the /web basename out of ids', () => {
  const state = settingsState();

  it.each([
    ['/web/timelines/list/42', 'list', 'list:42'],
    ['/timelines/list/42', 'list', 'list:42'],
    ['/web/timelines/tag/cat', 'hashtag', 'hashtag:cat'],
    ['/web/timelines/groups/9', 'group', 'group:9'],
    ['/web/accounts/7', 'account', 'account:7'],
    ['/web/timelines/mixes/3', 'mixTimeline', 'route:3'],
  ])('resolves %s', (pathname, layoutScope, expected) => {
    const source = resolveFullscreenSource(state, { layoutScope, pathname });

    expect(source).not.toBeNull();
    expect(source.dataTimelineId || source.mixColumnKey || source.timelineId).toEqual(expect.stringContaining(expected.split(':')[0] === 'route' ? 'route:3' : expected));
  });

  it('keeps a pinned list id when the browser URL is only /web', () => {
    const pinned = settingsState().setIn(['settings', 'columns'], fromJS([
      { uuid: 'list-col', id: 'LIST', params: { id: '99', layoutMode: 'normal' } },
    ]));
    const source = resolveFullscreenSource(pinned, { layoutScope: 'list', columnId: 'list-col', pathname: '/web' });

    expect(source.dataTimelineId).toBe('list:99');
    expect(stripRouterBasename('/web/timelines/list/42')).toBe('/timelines/list/42');
  });

  it('keeps hashtag any/all/none on the frozen expand params', () => {
    const tags = { any: [{ value: 'photo' }], all: [{ value: 'cat' }], none: [{ value: 'spoiler' }] };
    const source = resolveFullscreenSource(state, {
      layoutScope: 'hashtag',
      pathname: '/web/timelines/tag/cat',
      params: { id: 'cat', tags },
    });

    expect(source.expandParams.tags).toEqual(tags);
    expect(fromJS(source).getIn(['expandParams', 'tags']).toJS()).toEqual(tags);
  });
});

describe('fullscreen navigation and layers', () => {
  it('sends subtree pushes to the overlay and not the root history', () => {
    const root = [];
    const overlay = [];
    const history = createOverlayHistory({
      location: { pathname: '/timelines/home', search: '', hash: '', state: null },
      onNavigate: (path) => overlay.push(path),
      onBack: () => overlay.push('back'),
    });

    window.setTimeout(() => {
      history.push('/statuses/42');
      history.push('/timelines/home');
    }, 25);

    return new Promise((resolve) => {
      window.setTimeout(() => {
        expect(overlay).toEqual(['/statuses/42', '/timelines/home']);
        expect(root).toEqual([]);
        resolve();
      }, 40);
    });
  });

  it('gives React Router Link a createHref without touching the root history', () => {
    const root = createMemoryHistory({ initialEntries: ['/timelines/home'] });
    const overlay = [];
    const remember = (path) => {
      overlay.push(path);
    };
    const ignoreBack = () => {};
    const { getByText } = render(React.createElement(Router, { history: root },
      React.createElement(FullscreenRouter, { onNavigate: remember, onBack: ignoreBack },
        React.createElement(Link, { to: '/statuses/42' }, 'Open status'),
        React.createElement(NavLink, { to: '/accounts/7' }, 'Account'),
      ),
    ));

    expect(createOverlayHref({ pathname: '/statuses/42', search: '', hash: '' })).toBe('/statuses/42');
    expect(getByText('Open status').getAttribute('href')).toBe('/statuses/42');
    expect(getByText('Account').getAttribute('href')).toBe('/accounts/7');
    expect(root.location.pathname).toBe('/timelines/home');
    expect(overlay).toEqual([]);
  });

  it('keeps a frozen media-modal reply on its captured composer', () => {
    const actions = [];
    const state = fromJS({
      fullscreenColumn: { open: true, composerId: 'fullscreen:b' },
      compose: { text: 'primary draft', dirty: true, mounted: true },
      composers: {
        byId: {
          'fullscreen:a': { text: '', dirty: false, mounted: true },
          'fullscreen:b': { text: 'leave this draft', dirty: true, mounted: true },
        },
      },
    });
    const dispatch = (action) => {
      if (typeof action === 'function') {
        return action(dispatch, () => state);
      }

      actions.push(action);
      return action;
    };

    dispatch(dispatchFullscreenCompose('reply', fromJS({ id: '9', visibility: 'public', status_reference_ids: [] }), null, 'fullscreen:a'));

    const replies = actions.filter(action => action.type === 'COMPOSE_REPLY');

    expect(replies).toHaveLength(1);
    expect(replies[0].meta.composerId).toBe('fullscreen:a');
    expect(actions.some(action => action.type === 'FULLSCREEN_COLUMN_PATCH')).toBe(false);
    expect(state.getIn(['compose', 'text'])).toBe('primary draft');
    expect(state.getIn(['composers', 'byId', 'fullscreen:b', 'text'])).toBe('leave this draft');
  });

  it('skips covered stream controls and keeps a focused portal menu in its own tab cycle', () => {
    document.body.innerHTML = `
      <div id="column">
        <button id="bar">Bar</button>
        <div class="fullscreen-column__stream-hold--covered" inert>
          <button id="hidden-stream">Hidden</button>
        </div>
        <a id="detail" href="/statuses/1">Detail</a>
      </div>
      <div id="portal"><button id="emoji">Emoji</button><button id="tone">Tone</button></div>
    `;

    ['bar', 'hidden-stream', 'detail', 'emoji', 'tone'].forEach((id) => {
      Object.defineProperty(document.getElementById(id), 'offsetParent', { get: () => document.body });
    });

    const column = document.getElementById('column');
    const portal = document.getElementById('portal');
    const selector = 'button, a';

    expect(nodesInActiveLayer(column, document.getElementById('bar'), selector).map(node => node.id)).toEqual(['bar', 'detail']);
    expect(nodesInActiveLayer(portal, document.getElementById('emoji'), selector).map(node => node.id)).toEqual(['emoji', 'tone']);
    document.body.innerHTML = '';
  });

  it('keeps an edit result on the composer captured when the request started', () => {
    expect(capturedComposerDestination('fullscreen:a', null)).toEqual({ composerId: 'fullscreen:a', reveal: false });
    expect(capturedComposerDestination('fullscreen:a', 'fullscreen:b')).toEqual({ composerId: 'fullscreen:a', reveal: false });
    expect(capturedComposerDestination('fullscreen:a', 'fullscreen:a')).toEqual({ composerId: 'fullscreen:a', reveal: true });
    expect(capturedComposerDestination(null, 'fullscreen:a')).toEqual({ composerId: null, reveal: false });
  });

  it('orders browser-back depth as column, detail, then composer', () => {
    expect(fullscreenLayerDepth(null)).toBe(0);
    expect(fullscreenLayerDepth({ get: (key) => ({ paths: { size: 0 }, composerOpen: false }[key]) })).toBe(1);
    expect(fullscreenLayerDepth({ get: (key) => ({ paths: { size: 1 }, composerOpen: false }[key]) })).toBe(2);
    expect(fullscreenLayerDepth({ get: (key) => ({ paths: { size: 1 }, composerOpen: true }[key]) })).toBe(3);
  });
});

describe('fullscreen reading geometry', () => {
  it('applies the zoom conversion inside filter anchor restoration', () => {
    const scroller = document.createElement('div');
    document.body.appendChild(scroller);
    scroller.scrollTop = 400;
    const row = document.createElement('div');
    row.getBoundingClientRect = () => ({ top: 200, height: 20, bottom: 220, left: 0, right: 0, width: 0 });
    const node = document.createElement('div');
    node.contains = () => true;
    const snapshot = { offset: 400, abandoned: false, rows: [{ node: row, offset: 0 }], focused: null };
    const original = window.getComputedStyle;
    window.getComputedStyle = (element) => ({ zoom: element === scroller ? '2' : 'normal' });
    const accepted = [];

    restoreFilterAnchor(snapshot, node, scroller, 100, {
      onAcceptedScroll: (value) => accepted.push(value),
    });
    window.getComputedStyle = original;
    document.body.removeChild(scroller);

    expect(accepted).toEqual([450]);
    expect(scroller.scrollTop).toBe(450);
  });

  it('converts a zoomed visual delta into scrollTop units', () => {
    expect(scrollTopDeltaForVisualDelta(100, 2)).toBe(50);
    expect(scrollTopDeltaForVisualDelta(50, 1)).toBe(50);
    expect(scrollTopDeltaForVisualDelta(75, 1.5)).toBe(50);
  });

  it('moves to the second article inside masonry wrappers', () => {
    document.body.innerHTML = `
      <div id="flat"><article><div class="focusable" id="a"></div></article><article><div class="focusable" id="b"></div></article></div>
      <div id="masonry"><div class="timeline-masonry__item"><article><div class="focusable" id="c"></div></article></div><div class="timeline-masonry__item"><article><div class="focusable" id="d"></div></article></div></div>
    `;

    expect(articleFocusTarget(document.getElementById('flat'), 1).id).toBe('b');
    expect(articleFocusTarget(document.getElementById('masonry'), 1).id).toBe('d');
    document.body.innerHTML = '';
  });

  it('does not switch a live mix to history when fullscreen asks to preserve the view', () => {
    expect(mixExtendSwitchesToHistory('live', false)).toBe(true);
    expect(mixExtendSwitchesToHistory('live', true)).toBe(false);
    expect(mixExtendSwitchesToHistory('history', false)).toBe(false);
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
