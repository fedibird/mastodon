import React from 'react';
import PropTypes from 'prop-types';
import { defineMessages, injectIntl } from 'react-intl';
import { Link } from 'react-router-dom';
import Icon from 'mastodon/components/icon';

const VISIBLE_COUNT = 3;

const messages = defineMessages({
  shownVia: { id: 'mixes.shown_via', defaultMessage: 'Shown via' },
  more: { id: 'mixes.sources_more', defaultMessage: '{count} more' },
  openTimeline: { id: 'mixes.open_timeline', defaultMessage: 'Open original timeline' },
  warnings: { id: 'mixes.source_warnings', defaultMessage: 'Filter warnings' },
  close: { id: 'mixes.close_source', defaultMessage: 'Close source details' },
});

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
    document.removeEventListener('keydown', this.handleDocumentKeyDown);
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
    document.addEventListener('keydown', this.handleDocumentKeyDown);
  };

  closeMenu = (restoreFocus) => {
    const key = this.state.openKey;

    this.setState({ openKey: null });
    document.removeEventListener('keydown', this.handleDocumentKeyDown);

    if (restoreFocus && key && this.buttonRefs[key]) {
      this.buttonRefs[key].focus();
    }
  };

  handleDocumentKeyDown = (event) => {
    if (event.key === 'Escape') {
      event.preventDefault();
      this.closeMenu(true);
    }
  };

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

  renderMenu (badge) {
    const { intl } = this.props;

    return (
      <div className='status__mix-sources__menu' role='dialog' aria-label={badge.fullLabel}>
        <p className='status__mix-sources__menu-type'>{badge.typeLabel}</p>
        <p className='status__mix-sources__menu-name'>{badge.fullLabel}</p>
        {badge.conditions.map(line => (
          <p key={line} className='status__mix-sources__menu-detail'>{line}</p>
        ))}
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
  }

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
              {this.state.openKey === badge.key && this.renderMenu(badge)}
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
      </div>
    );
  }

}

export default injectIntl(MixSourceBadges);
