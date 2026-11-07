import React from 'react';
import PropTypes from 'prop-types';
import { connect } from 'react-redux';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { closeFullscreenColumn, patchFullscreenColumn, popFullscreenPath, pushFullscreenPath, setFullscreenComposerOpen } from 'mastodon/actions/fullscreen_column';
import { restoreFullscreenOpener, setActiveFullscreenComposerId } from 'mastodon/utils/fullscreen_column';
import { isTopOverlayLayer, registerOverlayLayer } from 'mastodon/utils/overlay_layers';
import PortableComposer from 'mastodon/features/compose/portable_composer';
import { FullscreenColumnContext } from './context';
import FullscreenColumnBar from './components/bar';
import FullscreenStream from './components/stream';
import FullscreenDetail from './components/detail';

const focusableSelector = 'button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

const mapStateToProps = (state) => ({
  session: state.get('fullscreenColumn'),
  layout: state.getIn(['meta', 'layout']),
});

class FullscreenColumnHost extends React.PureComponent {

  static contextTypes = {
    router: PropTypes.object,
  };

  static propTypes = {
    dispatch: PropTypes.func.isRequired,
    session: ImmutablePropTypes.map,
    layout: PropTypes.string,
  };

  componentDidMount () {
    document.addEventListener('keydown', this.handleKeyDown, true);

    if (this.props.session) {
      this.syncSession();
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
    }
  }

  componentWillUnmount () {
    document.removeEventListener('keydown', this.handleKeyDown, true);

    if (this.clearInteraction) {
      window.clearTimeout(this.clearInteraction);
    }

    this.teardownSession();
    this.unpatchHistory();
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
      this.installHistory();
    }

    setActiveFullscreenComposerId(session.get('source').get('supportsComposer') ? session.get('composerId') : null);
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
    this.unpatchHistory();
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
    const { session, dispatch } = this.props;
    const layers = [registerOverlayLayer({
      id: 'fullscreen-column',
      priority: 20,
      onEscape: () => dispatch(closeFullscreenColumn()),
    })];

    if (session.get('paths') && !session.get('paths').isEmpty()) {
      layers.push(registerOverlayLayer({
        id: 'fullscreen-detail',
        priority: 40,
        onEscape: () => dispatch(popFullscreenPath()),
      }));
    }

    if (session.get('composerOpen')) {
      layers.push(registerOverlayLayer({
        id: 'fullscreen-composer',
        priority: 60,
        onEscape: () => dispatch(setFullscreenComposerOpen(false)),
      }));
    }

    this.unregisterLayers = layers;
  }

  installHistory () {
    const history = this.context.router && this.context.router.history;

    if (!history) {
      return;
    }

    this.history = history;
    this.historyKey = this.props.session.get('viewId');
    const { pathname, search, hash, state } = history.location;

    if (!state || state.mastodonFullscreenKey !== this.historyKey) {
      history.push(`${pathname}${search}${hash}`, { ...(state || {}), mastodonFullscreenKey: this.historyKey });
    }

    this.unlistenHistory = history.listen((location, action) => {
      if (action !== 'POP' || this.closingHistory) {
        return;
      }

      const nextState = location.state || {};

      if (nextState.mastodonFullscreenKey === this.historyKey || nextState.mastodonModalKey) {
        return;
      }

      this.props.dispatch(closeFullscreenColumn());
    });
  }

  teardownHistory () {
    if (this.unlistenHistory) {
      this.unlistenHistory();
      this.unlistenHistory = null;
    }

    if (!this.history) {
      return;
    }

    const state = this.history.location.state || {};

    if (state.mastodonFullscreenKey === this.historyKey && !state.mastodonModalKey) {
      this.closingHistory = true;
      this.history.goBack();
      this.closingHistory = false;
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

    if (!root) {
      return;
    }

    const focusable = Array.from(root.querySelectorAll(focusableSelector)).filter(node => node.offsetParent !== null || node === document.activeElement);

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

  captureNavigation = (path) => {
    if (!this.props.session || !this.interactionInside) {
      return false;
    }

    const next = typeof path === 'string' ? path : (path && (path.pathname || path.path));

    if (!next || next === this.historyPath()) {
      return false;
    }

    this.props.dispatch(pushFullscreenPath(next));
    return true;
  };

  historyPath () {
    if (!this.history) {
      return null;
    }

    return this.history.location.pathname;
  }

  markInteraction = (event) => {
    if (this.hostNode && this.hostNode.contains(event.target)) {
      this.interactionInside = true;
      this.clearInteraction = window.setTimeout(() => {
        this.interactionInside = false;
      }, 0);
    }
  };

  setHost = (node) => {
    if (this.hostNode) {
      this.hostNode.removeEventListener('pointerdown', this.markInteraction, true);
      this.hostNode.removeEventListener('keydown', this.markInteraction, true);
    }

    this.hostNode = node;

    if (!node || !this.historyPatched) {
      this.patchHistory(node);
    }

    if (node) {
      node.addEventListener('pointerdown', this.markInteraction, true);
      node.addEventListener('keydown', this.markInteraction, true);
    }
  };

  patchHistory (node) {
    const history = this.context.router && this.context.router.history;

    if (!history || this.historyPatched) {
      return;
    }

    this.originalPush = history.push;
    this.originalReplace = history.replace;
    history.push = (path, state) => {
      if (!this.captureNavigation(path)) {
        this.originalPush.call(history, path, state);
      }
    };
    history.replace = (path, state) => {
      if (!this.captureNavigation(path)) {
        this.originalReplace.call(history, path, state);
      }
    };
    this.historyPatched = true;
    this.historyForPatch = history;
    void node;
  }

  unpatchHistory () {
    if (!this.historyPatched || !this.historyForPatch) {
      return;
    }

    this.historyForPatch.push = this.originalPush;
    this.historyForPatch.replace = this.originalReplace;
    this.historyPatched = false;
  }

  setColumn = (node) => {
    this.columnNode = node;
  };

  setComposer = (node) => {
    this.composerNode = node;
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
    this.props.dispatch(popFullscreenPath());
  }

  handleClose = () => {
    this.props.dispatch(closeFullscreenColumn());
  }

  handleComposerClose = () => {
    this.props.dispatch(setFullscreenComposerOpen(false));
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

    return (
      <FullscreenColumnContext.Provider value={session.get('viewId')}>
        <div className='fullscreen-column-host' ref={this.setHost}>
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
              {path ? <FullscreenDetail path={path} /> : <FullscreenStream session={session} />}
            </div>
          </div>
          {session.get('composerOpen') && source.get('supportsComposer') && (
            <div className='fullscreen-composer' role='dialog' aria-label='Composer' ref={this.setComposer}>
              <button type='button' className='fullscreen-composer__close' onClick={this.handleComposerClose}>
                ×
              </button>
              <PortableComposer
                composerId={session.get('composerId')}
                surface={surface ? surface.toJS() : undefined}
              />
            </div>
          )}
        </div>
      </FullscreenColumnContext.Provider>
    );
  }

}

export default connect(mapStateToProps)(FullscreenColumnHost);
