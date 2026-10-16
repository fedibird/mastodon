import React from 'react';
import ReactDOM from 'react-dom';
import { Provider, connect } from 'react-redux';
import { Router } from 'react-router-dom';
import { createMemoryHistory } from 'history';
import { IntlProvider } from 'react-intl';
import { createStore, applyMiddleware } from 'redux';
import thunk from 'redux-thunk';
import { List, fromJS } from 'immutable';
import rootReducer from '../../../app/javascript/mastodon/reducers';
import StatusList from '../../../app/javascript/mastodon/components/status_list';
import { importFetchedStatus, importStatuses } from '../../../app/javascript/mastodon/actions/importer';
import { filterReconciliationMiddleware, getFilterScheduler } from '../../../app/javascript/mastodon/filter_reconciliation/scheduler';
import { mixTimelineView } from '../../../app/javascript/mastodon/mix/view';
import { me } from '../../../app/javascript/mastodon/initial_state';

const params = new URLSearchParams(location.search);
let documentScroll = params.get('layout') === 'document';
let split = params.get('layout') === 'split';
const isMix = params.get('mix') === '1';
const count = Number(params.get('count')) || 120;
const ids = List(Array.from({ length: count }, (_, i) => String(count - i)));
const store = createStore(rootReducer, applyMiddleware(thunk, filterReconciliationMiddleware));
const account = { id: 'other', acct: 'other', username: 'other', display_name: 'Other', note: '', url: 'https://example.test/@other', emojis: [] };
store.dispatch(importFetchedStatus({ id: '120', account, content: 'fixture', spoiler_text: '', media_attachments: [], emojis: [], mentions: [], tags: [], filtered: [], reblog: null, quote: null, poll: null }));
const source = store.getState().getIn(['statuses', '120']).toJS();
store.dispatch(importStatuses(ids.map(id => ({ ...source, id })).toArray()));
let revision = 0;
const definition = (action = 'hide') => ({ id: '1', title: 'browser fixture', context: ['home'], filter_action: action, expires_at: null, keywords: [{ id: '10', keyword: String(revision), whole_word: false }], statuses: [] });
const snapshot = action => store.dispatch({ type: 'FILTERS_FETCH_SUCCESS', filters: [definition(action)], receivedAt: Date.now() });
snapshot('hide');
window.fixtureMatches = [];
window.fixturePosts = [];
const mixTimeline = fromJS({ sources: { home: { descriptor: { type: 'home', params: {} }, ids: ids.toArray(), loaded: true, hasMore: false, filterResults: {} } }, live: {}, pendingStatusIds: [], deletedStatusIds: [] });
const contextFor = view => id => view.contextById[id];
const MixList = connect(state => ({ view: mixTimelineView(mixTimeline, state.get('statuses'), state.get('filters'), me, undefined, state.get('filterMatches')) }))(({ view, ...props }) => <StatusList {...props} statusIds={view.statusIds} filterStatusIds={view.reconciliationIds} contextTypeForId={contextFor(view)} />);
const TestList = isMix ? MixList : StatusList;
const widthForLayout = () => {
  if (documentScroll) return '100%';
  return split ? 680 : 420;
};
const heightForLayout = () => {
  if (documentScroll) return 'auto';
  return split ? '340px' : '600px';
};
const tree = () => (
  <IntlProvider locale='en'><Router history={history}><Provider store={store}>
    <div id='panes' style={{ display: split ? 'block' : 'flex', gap: 16 }}>
      {Array.from({ length: documentScroll ? 1 : 2 }, (_, i) => (
        <section key={i} id={`pane-${i}`} style={{ width: widthForLayout() }}>
          <TestList scrollKey={`browser-${i}`} statusIds={ids} timelineId='home' trackScroll={false} bindToDocument={documentScroll} trackIntersection={false} />
        </section>
      ))}
    </div>
    <textarea id='composer' defaultValue='portable draft retained' />
  </Provider></Router></IntlProvider>
);
const root = document.getElementById('root');
const history = createMemoryHistory();
ReactDOM.render(tree(), root);
window.fixture = {
  store,
  change(matches, action = 'hide', displayOnly = false) {
    if (params.get('anchors') === 'off') getFilterScheduler(store.dispatch, store.getState).surfaces.forEach((surface, token) => {
      token.prepare = () => {};
    });
    window.fixtureMatches = matches;
    if (!displayOnly) revision++;
    snapshot(action);
  },
  layout() {
    return { documentScroll, split, isMix };
  },
  switchLayout(layout) {
    documentScroll = layout === 'document';
    split = layout === 'split';
    const style = document.createElement('style');
    style.textContent = `.scrollable { height: ${heightForLayout()}; overflow-y: ${documentScroll ? 'visible' : 'auto'}; overflow-anchor: none; }`;
    document.head.appendChild(style);
    ReactDOM.render(tree(), root);
  },
  stats: () => getFilterScheduler(store.dispatch, store.getState).stats(),
  unmount: () => ReactDOM.unmountComponentAtNode(root),
};
