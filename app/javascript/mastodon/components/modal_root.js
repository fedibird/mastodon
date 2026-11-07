import React from 'react';
import PropTypes from 'prop-types';
import 'wicg-inert';
import { createBrowserHistory } from 'history';
import { multiply } from 'color-blend';
import { isTopOverlayLayer, registerOverlayLayer } from 'mastodon/utils/overlay_layers';

export default class ModalRoot extends React.PureComponent {

  static contextTypes = {
    router: PropTypes.object,
  };

  static propTypes = {
    children: PropTypes.node,
    onClose: PropTypes.func.isRequired,
    backgroundColor: PropTypes.shape({
      r: PropTypes.number,
      g: PropTypes.number,
      b: PropTypes.number,
    }),
  };

  activeElement = this.props.children ? document.activeElement : null;

  handleKeyUp = () => {
    // Escape is owned by the shared overlay stack. This listener stays so a
    // modal opened before registration still has a keyup subscriber, but it
    // must not close together with a higher or lower surface.
  }

  unregisterLayer = () => {
    if (this.unregisterOverlay) {
      this.unregisterOverlay();
      this.unregisterOverlay = null;
    }
  }

  registerLayer = () => {
    this.unregisterLayer();

    if (!this.props.children) {
      return;
    }

    this.unregisterOverlay = registerOverlayLayer({
      id: 'modal-root',
      priority: 80,
      onEscape: () => this.props.onClose(),
    });
  }

  handleKeyDown = (e) => {
    if (e.key === 'Tab' && isTopOverlayLayer('modal-root')) {
      const focusable = Array.from(this.node.querySelectorAll('button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])')).filter((x) => window.getComputedStyle(x).display !== 'none');
      const index = focusable.indexOf(e.target);

      let element;

      if (e.shiftKey) {
        element = focusable[index - 1] || focusable[focusable.length - 1];
      } else {
        element = focusable[index + 1] || focusable[0];
      }

      if (element) {
        element.focus();
        e.stopPropagation();
        e.preventDefault();
      }
    }
  }

  componentDidMount () {
    window.addEventListener('keyup', this.handleKeyUp, false);
    window.addEventListener('keydown', this.handleKeyDown, false);
    this.history = this.context.router ? this.context.router.history : createBrowserHistory();
    this.registerLayer();
  }

  componentWillReceiveProps (nextProps) {
    if (!!nextProps.children && !this.props.children) {
      this.activeElement = document.activeElement;

      this.getSiblings().forEach(sibling => sibling.setAttribute('inert', true));
    }
  }

  componentDidUpdate (prevProps) {
    if (!!this.props.children !== !!prevProps.children) {
      this.registerLayer();
    }

    if (!this.props.children && !!prevProps.children) {
      this.getSiblings().forEach(sibling => {
        if (sibling.nodeType === 1 && sibling.getAttribute('data-keep-inert') === 'true') {
          return;
        }

        if (sibling.removeAttribute) {
          sibling.removeAttribute('inert');
        }
      });

      // Because of the wicg-inert polyfill, the activeElement may not be
      // immediately selectable, we have to wait for observers to run, as
      // described in https://github.com/WICG/inert#performance-and-gotchas
      Promise.resolve().then(() => {
        this.activeElement.focus({ preventScroll: true });
        this.activeElement = null;
      }).catch(console.error);

      this._handleModalClose();
    }
    if (this.props.children && !prevProps.children) {
      this._handleModalOpen();
    }
    if (this.props.children) {
      this._ensureHistoryBuffer();
    }
  }

  componentWillUnmount () {
    window.removeEventListener('keyup', this.handleKeyUp);
    window.removeEventListener('keydown', this.handleKeyDown);
    this.unregisterLayer();
  }

  _handleModalOpen () {
    this._modalHistoryKey = Date.now();
    this.unlistenHistory = this.history.listen((_, action) => {
      if (action === 'POP') {
        this.props.onClose();
      }
    });
  }

  _handleModalClose () {
    if (this.unlistenHistory) {
      this.unlistenHistory();
    }
    const { state } = this.history.location;
    if (state && state.mastodonModalKey === this._modalHistoryKey) {
      this.history.goBack();
    }
  }

  _ensureHistoryBuffer () {
    const { pathname, state } = this.history.location;
    if (!state || state.mastodonModalKey !== this._modalHistoryKey) {
      this.history.push(pathname, { ...state, mastodonModalKey: this._modalHistoryKey });
    }
  }

  getSiblings = () => {
    return Array(...this.node.parentElement.childNodes).filter(node => node !== this.node);
  }

  setRef = ref => {
    this.node = ref;
  }

  render () {
    const { children, onClose } = this.props;
    const visible = !!children;

    if (!visible) {
      return (
        <div className='modal-root' ref={this.setRef} style={{ opacity: 0 }} />
      );
    }

    let backgroundColor = null;

    if (this.props.backgroundColor) {
      backgroundColor = multiply({ ...this.props.backgroundColor, a: 1 }, { r: 0, g: 0, b: 0, a: 0.7 });
    }

    return (
      <div className='modal-root' ref={this.setRef}>
        <div style={{ pointerEvents: visible ? 'auto' : 'none' }}>
          <div role='presentation' className='modal-root__overlay' onClick={onClose} style={{ backgroundColor: backgroundColor ? `rgba(${backgroundColor.r}, ${backgroundColor.g}, ${backgroundColor.b}, 0.7)` : null }} />
          <div role='dialog' className='modal-root__container'>{children}</div>
        </div>
      </div>
    );
  }

}
