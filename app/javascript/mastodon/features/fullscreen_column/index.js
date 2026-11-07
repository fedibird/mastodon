import React from 'react';
import PropTypes from 'prop-types';
import { connect } from 'react-redux';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { closeFullscreenColumn, patchFullscreenColumn, popFullscreenPath, pushFullscreenPath, setFullscreenComposerOpen } from 'mastodon/actions/fullscreen_column';
import { restoreFullscreenOpener, setActiveFullscreenComposerId } from 'mastodon/utils/fullscreen_column';
import { isTopOverlayLayer, registerOverlayLayer } from 'mastodon/utils/overlay_layers';
import { selectPostingContextForAccount } from 'mastodon/selectors/posting_contexts';
import { buildHashtagTimelinePostingContext } from 'mastodon/posting_context/hashtag';
import { stripRouterBasename } from './sources';
import PortableComposer from 'mastodon/features/compose/portable_composer';
import { FullscreenColumnContext } from './context';
import FullscreenColumnBar from './components/bar';
import FullscreenStream from './components/stream';
import FullscreenDetail from './components/detail';
import { FullscreenRouter, fullscreenLayerDepth } from './overlay_history';
import { nodesInActiveLayer, setFullscreenOverlayPortal } from 'mastodon/utils/overlay_portal';

const focusableSelector = 'button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

const mapStateToProps = (state) => {
  const session = state.get('fullscreenColumn');
  const surface = session && session.getIn(['source', 'surface']);
  const kind = surface && surface.get('kind');
  const key = surface && surface.get('key');
  let postingContext = null;
  let postingContextAccountId = null;

  if (kind === 'group' && key) {
    postingContext = selectPostingContextForAccount(state, key);
    postingContextAccountId = key;
  } else if (kind === 'hashtag' && key) {
    postingContext = buildHashtagTimelinePostingContext(key);
  }

  return {
    session,
    layout: state.getIn(['meta', 'layout']),
    postingContext,
    postingContextAccountId,
  };
};

class FullscreenColumnHost extends React.PureComponent {

  static contextTypes = {
    router: PropTypes.object,
  };

  static propTypes = {
    dispatch: PropTypes.func.isRequired,
    session: ImmutablePropTypes.map,
    layout: PropTypes.string,
    postingContext: PropTypes.object,
    postingContextAccountId: PropTypes.string,
  };

  componentDidMount () {
    document.addEventListener('keydown', this.handleKeyDown, true);

    if (this.props.session) {
      this.syncSession();
      this.pushHistoryIfDeeper(null);
    }
  }

  componentDidUpdate (prevProps) {
    if (prevProps.layout !== 'mobile' && this.props.layout === 'mobile' && this.props.session) {
      this.props.dispatch(closeFullscreenColumn());
      return;
    }

    if (prevProps.session === this.props.session) {
      return;
    }

    if (!this.props.session) {
      this.teardownSession();
    } else {
      this.syncSession(prevProps.session);
      if (!this.fromPop) {
        this.pushHistoryIfDeeper(prevProps.session);
      }
    }
  }

  componentWillUnmount () {
    document.removeEventListener('keydown', this.handleKeyDown, true);
    setFullscreenOverlayPortal(null);
    this.teardownSession();
  }

  syncSession (previous) {
    const { session } = this.props;

    if (!session) {
      this.teardownSession();
      return;
    }

    const viewChanged = !previous || previous.get('viewId') !== session.get('viewId');

    if (viewChanged) {
      this.teardownHistory();
      this.ensureHistoryListener();
    }

    setActiveFullscreenComposerId(session.get('composerId'));
    this.applyInert(true);
    this.registerLayers();

    if (!previous) {
      const focusTarget = this.columnNode && this.columnNode.querySelector('button, [href], input, textarea');

      if (focusTarget) {
        focusTarget.focus({ preventScroll: true });
      }
    }
  }

  teardownSession () {
    this.teardownHistory();
    this.clearLayers();
    this.applyInert(false);
    setActiveFullscreenComposerId(null);
    restoreFullscreenOpener();
  }

  applyInert (active) {
    const background = document.querySelector('[data-fullscreen-background]');

    if (!background) {
      return;
    }

    if (active) {
      background.setAttribute('inert', '');
      background.setAttribute('data-keep-inert', 'true');
    } else {
      background.removeAttribute('data-keep-inert');

      if (!document.querySelector('.modal-root__container')) {
        background.removeAttribute('inert');
      }
    }
  }

  clearLayers () {
    if (this.unregisterLayers) {
      this.unregisterLayers.forEach(unregister => unregister());
      this.unregisterLayers = null;
    }
  }

  registerLayers () {
    this.clearLayers();
    const { session } = this.props;
    const layers = [registerOverlayLayer({
      id: 'fullscreen-column',
      priority: 20,
      onEscape: () => this.requestLayerBack(),
    })];

    if (session.get('paths') && !session.get('paths').isEmpty()) {
      layers.push(registerOverlayLayer({
        id: 'fullscreen-detail',
        priority: 40,
        onEscape: () => this.requestLayerBack(),
      }));
    }

    if (session.get('composerOpen')) {
      layers.push(registerOverlayLayer({
        id: 'fullscreen-composer',
        priority: 60,
        onEscape: () => this.requestLayerBack(),
      }));
    }

    this.unregisterLayers = layers;
  }

  rootHistory () {
    return this.context.router && this.context.router.history;
  }

  ensureHistoryListener () {
    const history = this.rootHistory();

    if (!history || this.unlistenHistory) {
      return;
    }

    this.history = history;
    this.historyKey = this.props.session && this.props.session.get('viewId');
    this.unlistenHistory = history.listen(this.onHistory);
  }

  pushHistoryIfDeeper (previous) {
    const history = this.rootHistory();
    const session = this.props.session;

    if (!history || !session || this.fromPop) {
      return;
    }

    const depth = fullscreenLayerDepth(session);
    const previousDepth = fullscreenLayerDepth(previous);

    if (depth <= previousDepth) {
      return;
    }

    const { pathname, search, hash, state } = history.location;

    history.push(`${pathname}${search}${hash}`, {
      ...(state || {}),
      mastodonFullscreenKey: session.get('viewId'),
      mastodonFullscreenDepth: depth,
    });
  }

  onHistory = (location, action) => {
    if (action !== 'POP' || !this.props.session) {
      return;
    }

    const next = location.state || {};
    const key = this.props.session.get('viewId');

    if (this.closingAll || next.mastodonFullscreenKey !== key) {
      this.closingAll = false;
      this.fromPop = true;
      this.props.dispatch(closeFullscreenColumn());
      this.fromPop = false;
      return;
    }

    const nextDepth = next.mastodonFullscreenDepth || 1;

    if (nextDepth >= fullscreenLayerDepth(this.props.session)) {
      return;
    }

    this.fromPop = true;
    this.closeTopLayer();
    this.fromPop = false;
  }

  closeTopLayer () {
    const session = this.props.session;

    if (!session) {
      return;
    }

    if (session.get('composerOpen')) {
      this.props.dispatch(setFullscreenComposerOpen(false));
      return;
    }

    if (session.get('paths') && !session.get('paths').isEmpty()) {
      this.props.dispatch(popFullscreenPath());
      return;
    }

    this.props.dispatch(closeFullscreenColumn());
  }

  requestLayerBack = () => {
    const history = this.rootHistory();
    const state = history && history.location.state;
    const session = this.props.session;

    if (history && session && state && state.mastodonFullscreenKey === session.get('viewId') && !state.mastodonModalKey) {
      history.goBack();
      return;
    }

    this.closeTopLayer();
  }

  teardownHistory () {
    if (this.unlistenHistory) {
      this.unlistenHistory();
      this.unlistenHistory = null;
    }

    const history = this.history;
    const state = history && history.location.state;

    if (!this.fromPop && !this.closingAll && history && state && state.mastodonFullscreenKey === this.historyKey && !state.mastodonModalKey) {
      history.go(-(state.mastodonFullscreenDepth || 1));
    }

    this.history = null;
    this.historyKey = null;
  }

  handleKeyDown = (event) => {
    if (event.key !== 'Tab' || !this.props.session) {
      return;
    }

    let topId = 'fullscreen-column';

    if (this.props.session.get('composerOpen')) {
      topId = 'fullscreen-composer';
    } else if (this.props.session.get('paths') && !this.props.session.get('paths').isEmpty()) {
      topId = 'fullscreen-detail';
    }

    if (!isTopOverlayLayer(topId)) {
      return;
    }

    const root = topId === 'fullscreen-composer' ? this.composerNode : this.columnNode;

    if (!root && !(this.portalNode && this.portalNode.contains(document.activeElement))) {
      return;
    }

    const portalOwnsFocus = this.portalNode && this.portalNode.contains(document.activeElement);
    const scopeRoot = portalOwnsFocus ? this.portalNode : root;
    const focusable = nodesInActiveLayer(scopeRoot, document.activeElement, focusableSelector);

    if (focusable.length === 0) {
      return;
    }

    const index = focusable.indexOf(document.activeElement);
    const next = event.shiftKey
      ? (focusable[index - 1] || focusable[focusable.length - 1])
      : (focusable[index + 1] || focusable[0]);

    if (next) {
      next.focus();
      event.preventDefault();
      event.stopPropagation();
    }
  };

  handleOverlayNavigate = (path, _state, replace) => {
    const history = this.rootHistory();
    const current = history ? `${history.location.pathname}${history.location.search || ''}` : '';
    const next = stripRouterBasename(path || '');

    if (!next || next === current || next === (history && history.location.pathname)) {
      return;
    }

    if (replace) {
      const paths = this.props.session.get('paths');
      const nextPaths = paths && !paths.isEmpty() ? paths.set(paths.size - 1, next) : paths.push(next);
      this.props.dispatch(patchFullscreenColumn({ paths: nextPaths }));
      return;
    }

    this.props.dispatch(pushFullscreenPath(next));
  }

  setColumn = (node) => {
    this.columnNode = node;
  };

  setComposer = (node) => {
    this.composerNode = node;
  };

  setPortal = (node) => {
    this.portalNode = node;
    setFullscreenOverlayPortal(node);
  };

  updatePresentation (patch) {
    const presentation = this.props.session.get('presentation').merge(patch);
    this.props.dispatch(patchFullscreenColumn({ presentation }));
  }

  handleAppearance = (appearance) => {
    this.updatePresentation({ appearance });
  }

  handleColumns = (columns) => {
    this.updatePresentation({ columns: Number(columns) });
  }

  handleScale = (scale) => {
    this.updatePresentation({ scale });
  }

  handleMediaShape = (mediaShape) => {
    this.updatePresentation({ mediaShape });
  }

  handleMediaSize = (mediaSize) => {
    this.updatePresentation({ mediaSize });
  }

  handleMediaVisibility = (mediaVisibility) => {
    this.updatePresentation({ mediaVisibility });
  }

  handleCompose = () => {
    this.props.dispatch(setFullscreenComposerOpen(true));
  }

  handleBack = () => {
    this.requestLayerBack();
  }

  handleClose = () => {
    const history = this.rootHistory();
    const session = this.props.session;
    const state = history && history.location.state;
    const depth = fullscreenLayerDepth(session);

    if (history && session && state && state.mastodonFullscreenKey === session.get('viewId') && !state.mastodonModalKey) {
      this.closingAll = true;
      history.go(-depth);
      return;
    }

    this.props.dispatch(closeFullscreenColumn());
  }

  handleComposerClose = () => {
    this.requestLayerBack();
  }

  render () {
    const { session } = this.props;

    if (!session || !session.get('open')) {
      return null;
    }

    const source = session.get('source');
    const presentation = session.get('presentation');
    const appearance = presentation.get('appearance');
    const path = session.get('paths') && session.get('paths').last();
    const surface = source.get('surface');

    const covered = !!path;

    return (
      <FullscreenColumnContext.Provider value={session.get('viewId')}>
        <FullscreenRouter onNavigate={this.handleOverlayNavigate} onBack={this.requestLayerBack}>
          <div className='fullscreen-column-host'>
            <div
              className='fullscreen-column'
              id='fullscreen-column'
              role='dialog'
              aria-modal='true'
              aria-label={source.get('title') || ''}
              data-fullscreen-column='true'
              ref={this.setColumn}
            >
              <FullscreenColumnBar
                title={source.get('title') || ''}
                appearance={appearance}
                columns={Number(presentation.get('columns')) || 1}
                scale={presentation.get('scale')}
                supportsStatusLayout={source.get('supportsStatusLayout')}
                supportsComposer={source.get('supportsComposer')}
                supportsMediaControls={source.get('supportsMediaControls')}
                canGoBack={!!path}
                mediaShape={presentation.get('mediaShape')}
                mediaSize={presentation.get('mediaSize')}
                mediaVisibility={presentation.get('mediaVisibility')}
                onAppearance={this.handleAppearance}
                onColumns={this.handleColumns}
                onScale={this.handleScale}
                onMediaShape={this.handleMediaShape}
                onMediaSize={this.handleMediaSize}
                onMediaVisibility={this.handleMediaVisibility}
                onCompose={this.handleCompose}
                onBack={this.handleBack}
                onClose={this.handleClose}
              />
              <div className='fullscreen-column__body'>
                <div
                  className={covered ? 'fullscreen-column__stream fullscreen-column__stream-hold--covered' : 'fullscreen-column__stream'}
                  inert={covered ? '' : null}
                >
                  <FullscreenStream session={session} />
                </div>
                {covered && (
                  <div className='fullscreen-column__detail'>
                    <FullscreenDetail path={path} />
                  </div>
                )}
              </div>
            </div>
            {session.get('composerOpen') && (
              <div className='fullscreen-composer' role='dialog' aria-label='Composer' ref={this.setComposer}>
                <button type='button' className='fullscreen-composer__close' onClick={this.handleComposerClose}>
                  ×
                </button>
                <PortableComposer
                  composerId={session.get('composerId')}
                  surface={surface ? surface.toJS() : undefined}
                  postingContext={this.props.postingContext || undefined}
                  postingContextAccountId={this.props.postingContextAccountId || undefined}
                />
              </div>
            )}
          </div>
        </FullscreenRouter>
        <div className='fullscreen-column-portal' ref={this.setPortal} />
      </FullscreenColumnContext.Provider>
    );
  }

}

export default connect(mapStateToProps)(FullscreenColumnHost);
