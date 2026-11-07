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
export const createOverlayHref = (loc) => {
  if (!loc) {
    return '/';
  }

  if (typeof loc === 'string') {
    return loc;
  }

  return `${loc.pathname || ''}${loc.search || ''}${loc.hash || ''}`;
};

export const createOverlayHistory = ({ location, onNavigate, onBack, createHref }) => {
  const current = {
    pathname: '/',
    search: '',
    hash: '',
    state: null,
    ...(location || {}),
  };

  const remember = (path, state) => {
    if (typeof path === 'string') {
      const hashIndex = path.indexOf('#');
      const searchIndex = path.indexOf('?');
      let pathnameEnd = path.length;

      if (searchIndex >= 0) {
        pathnameEnd = searchIndex;
      } else if (hashIndex >= 0) {
        pathnameEnd = hashIndex;
      }

      let search = '';

      if (searchIndex >= 0) {
        const searchEnd = hashIndex >= 0 ? hashIndex : path.length;
        search = path.slice(searchIndex, searchEnd);
      }

      current.pathname = path.slice(0, pathnameEnd) || '/';
      current.search = search;
      current.hash = hashIndex >= 0 ? path.slice(hashIndex) : '';
    } else if (path) {
      current.pathname = path.pathname || current.pathname;
      current.search = path.search || '';
      current.hash = path.hash || '';
    }

    current.state = state === undefined ? current.state : state;
  };

  return {
    action: 'PUSH',
    length: 1,
    push (path, state) {
      remember(path, state);
      onNavigate(locationPath(path), state, false);
    },
    replace (path, state) {
      remember(path, state);
      onNavigate(locationPath(path), state, true);
    },
    goBack () {
      onBack();
    },
    goForward () {},
    go () {
      onBack();
    },
    block () {
      return () => {};
    },
    listen () {
      return () => {};
    },
    createHref: typeof createHref === 'function' ? createHref : createOverlayHref,
    get location () {
      return current;
    },
  };
};

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
      createHref: root && root.createHref ? (loc) => root.createHref(loc) : undefined,
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
