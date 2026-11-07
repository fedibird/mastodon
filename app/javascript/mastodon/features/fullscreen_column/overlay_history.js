import React from 'react';
import PropTypes from 'prop-types';

export const fullscreenLayerDepth = (session) => {
  if (!session) {
    return 0;
  }

  const paths = typeof session.get === 'function' ? session.get('paths') : session.paths;
  const composerOpen = typeof session.get === 'function' ? session.get('composerOpen') : session.composerOpen;
  const pathCount = paths && typeof paths.size === 'number' ? paths.size : 0;

  return 1 + pathCount + (composerOpen ? 1 : 0);
};

const locationPath = (path) => {
  if (!path) {
    return '';
  }

  if (typeof path === 'string') {
    return path;
  }

  return `${path.pathname || ''}${path.search || ''}${path.hash || ''}`;
};

// Calls from the fullscreen React tree never reach the root history, including
// pushes that happen after the click that opened the composer.
export const createOverlayHistory = ({ location, onNavigate, onBack }) => ({
  push (path, state) {
    onNavigate(locationPath(path), state, false);
  },

  replace (path, state) {
    onNavigate(locationPath(path), state, true);
  },

  goBack () {
    onBack();
  },

  go () {
    onBack();
  },

  listen () {
    return () => {};
  },

  location: location || { pathname: '/', search: '', hash: '', state: null },
});

export class FullscreenRouter extends React.Component {

  static contextTypes = {
    router: PropTypes.object,
  };

  static childContextTypes = {
    router: PropTypes.object,
  };

  static propTypes = {
    onNavigate: PropTypes.func.isRequired,
    onBack: PropTypes.func.isRequired,
    children: PropTypes.node,
  };

  constructor (props, context) {
    super(props, context);
    const root = context.router && context.router.history;

    this.history = createOverlayHistory({
      location: root ? root.location : { pathname: '/', search: '', hash: '', state: null },
      onNavigate: props.onNavigate,
      onBack: props.onBack,
    });
  }

  getChildContext () {
    const parent = this.context.router || {};

    return {
      router: {
        ...parent,
        history: this.history,
      },
    };
  }

  render () {
    return this.props.children;
  }

}
