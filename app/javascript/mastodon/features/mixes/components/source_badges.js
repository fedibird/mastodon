import React from 'react';
import PropTypes from 'prop-types';
import { defineMessages, injectIntl } from 'react-intl';
import { Link } from 'react-router-dom';
import Overlay from 'react-overlays/Overlay';
import Icon from 'mastodon/components/icon';

const VISIBLE_COUNT = 3;

const messages = defineMessages({
  shownVia: { id: 'mixes.shown_via', defaultMessage: 'Shown via' },
  more: { id: 'mixes.sources_more', defaultMessage: '{count} more' },
  openTimeline: { id: 'mixes.open_timeline', defaultMessage: 'Open original timeline' },
  settingsDiffer: { id: 'mixes.timeline_settings_differ', defaultMessage: 'The regular timeline uses your current settings, not this saved mix.' },
  warnings: { id: 'mixes.source_warnings', defaultMessage: 'Filter warnings' },
  close: { id: 'mixes.close_source', defaultMessage: 'Close source details' },
});

const POPPER_CONFIG = {
  strategy: 'fixed',
  modifiers: [
    {
      name: 'preventOverflow',
      options: {
        boundary: 'viewport',
        altAxis: true,
        padding: 8,
      },
    },
    {
      name: 'flip',
      options: {
        boundary: 'viewport',
        padding: 8,
        fallbackPlacements: ['top-start', 'bottom-start'],
      },
    },
  ],
};

const MENU_STYLE = {
  width: '18em',
  maxWidth: 'calc(100vw - 16px)',
};

class MixSourceBadges extends React.PureComponent {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    badges: PropTypes.array,
  };

  state = {
    expanded: false,
    openKey: null,
  };

  buttonRefs = {};

  componentWillUnmount () {
    this.clearMenuListeners();
  }

  handleBadgeRef = (node) => {
    if (!node) {
      return;
    }

    this.buttonRefs[node.getAttribute('data-source-key')] = node;
  };

  handleBadgeClick = (event) => {
    this.handleToggle(event.currentTarget.getAttribute('data-source-key'));
  };

  handleCloseClick = () => {
    this.closeMenu(true);
  };

  handleOpenTimeline = () => {
    this.closeMenu(false);
  };

  openMenu = (key) => {
    this.setState({ openKey: key });
  };

  closeMenu = (restoreFocus) => {
    const key = this.state.openKey;

    this.setState({ openKey: null });

    if (restoreFocus && key && this.buttonRefs[key]) {
      this.buttonRefs[key].focus();
    }
  };

  clearMenuListeners = () => {
    if (!this.menuListening) {
      return;
    }

    this.menuListening = false;
    document.removeEventListener('click', this.handleDocumentClick, false);
    document.removeEventListener('keydown', this.handleDocumentKeyDown, false);
  };

  handleMenuMount = (node) => {
    this.menuNode = node;

    if (!node) {
      this.clearMenuListeners();
      return;
    }

    if (this.menuListening) {
      return;
    }

    this.menuListening = true;
    document.addEventListener('click', this.handleDocumentClick, false);
    document.addEventListener('keydown', this.handleDocumentKeyDown, false);
  };

  handleDocumentClick = (event) => {
    const anchor = this.buttonRefs[this.state.openKey];

    if (this.menuNode && this.menuNode.contains(event.target)) {
      return;
    }

    if (anchor && anchor.contains(event.target)) {
      return;
    }

    this.closeMenu(false);
  };

  handleDocumentKeyDown = (event) => {
    if (event.key === 'Escape') {
      event.preventDefault();
      this.closeMenu(true);
    }
  };

  findTarget = () => this.buttonRefs[this.state.openKey] || null;

  handleToggle = (key) => {
    if (this.state.openKey === key) {
      this.closeMenu(false);
      return;
    }

    this.openMenu(key);
  };

  handleExpand = () => {
    this.setState({ expanded: true });
  };

  renderOverlay = ({ props, placement }) => {
    const badge = (this.props.badges || []).find(item => item.key === this.state.openKey);

    if (!badge) {
      return null;
    }

    const { intl } = this.props;
    const style = { ...props.style, ...MENU_STYLE };

    return (
      <div
        {...props}
        className={`status__mix-sources__menu ${placement || ''}`}
        style={style}
        role='dialog'
        aria-label={badge.fullLabel}
        ref={this.handleMenuMount}
      >
        <p className='status__mix-sources__menu-type'>{badge.typeLabel}</p>
        <p className='status__mix-sources__menu-name'>{badge.fullLabel}</p>
        {badge.conditions.map(line => (
          <p key={line} className='status__mix-sources__menu-detail'>{line}</p>
        ))}
        {badge.settingsDiffer && (
          <p className='status__mix-sources__menu-note'>{intl.formatMessage(messages.settingsDiffer)}</p>
        )}
        {badge.warningTitles.length > 0 && (
          <div className='status__mix-sources__menu-warn'>
            <p>{intl.formatMessage(messages.warnings)}</p>
            {badge.warningTitles.map(title => <p key={title}>{title}</p>)}
          </div>
        )}
        {badge.href && (
          <Link className='status__mix-sources__menu-link' to={badge.href} onClick={this.handleOpenTimeline}>
            {intl.formatMessage(messages.openTimeline)}
          </Link>
        )}
        <button type='button' className='status__mix-sources__menu-close' onClick={this.handleCloseClick}>
          {intl.formatMessage(messages.close)}
        </button>
      </div>
    );
  };

  render () {
    const { intl, badges } = this.props;

    if (!badges || !badges.length) {
      return null;
    }

    const hiddenCount = badges.length - VISIBLE_COUNT;
    const shown = this.state.expanded || hiddenCount <= 0 ? badges : badges.slice(0, VISIBLE_COUNT);

    return (
      <div className='status__mix-sources'>
        <span className='status__mix-sources__label'>{intl.formatMessage(messages.shownVia)}</span>
        <ul className='status__mix-sources__list'>
          {shown.map(badge => (
            <li key={badge.key} className='status__mix-sources__item'>
              <button
                type='button'
                className='status__mix-sources__badge'
                title={badge.fullLabel}
                data-source-key={badge.key}
                aria-expanded={this.state.openKey === badge.key ? 'true' : 'false'}
                ref={this.handleBadgeRef}
                onClick={this.handleBadgeClick}
              >
                <Icon id={badge.icon} className='status__mix-sources__icon' />
                <span className='status__mix-sources__badge-label'>{badge.label}</span>
              </button>
            </li>
          ))}
          {!this.state.expanded && hiddenCount > 0 && (
            <li className='status__mix-sources__item'>
              <button type='button' className='status__mix-sources__more' onClick={this.handleExpand}>
                {intl.formatMessage(messages.more, { count: hiddenCount })}
              </button>
            </li>
          )}
        </ul>
        <Overlay
          show={!!this.state.openKey}
          placement='bottom-start'
          flip
          offset={[0, 4]}
          target={this.findTarget}
          popperConfig={POPPER_CONFIG}
        >
          {this.renderOverlay}
        </Overlay>
      </div>
    );
  }

}

export default injectIntl(MixSourceBadges);
