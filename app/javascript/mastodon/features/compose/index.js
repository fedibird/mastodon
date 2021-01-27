import React, { Fragment } from 'react';
import ComposeFormContainer from './containers/compose_form_container';
import NavigationContainer from './containers/navigation_container';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { connect } from 'react-redux';
import { mountCompose, unmountCompose } from '../../actions/compose';
import { Link } from 'react-router-dom';
import { injectIntl, defineMessages } from 'react-intl';
import SearchContainer from './containers/search_container';
import Motion from '../ui/util/optional_motion';
import spring from 'react-motion/lib/spring';
import SearchResultsContainer from './containers/search_results_container';
import { changeComposing } from '../../actions/compose';
import { openModal } from 'mastodon/actions/modal';
import elephantUIPlane from '../../../images/elephant_ui_plane.svg';
import { mascot, show_tab_bar_label } from '../../initial_state';
import Icon from 'mastodon/components/icon';
import { logOut } from 'mastodon/utils/log_out';
import NotificationsCounterIcon from '../ui/components/notifications_counter_icon';
import classNames from 'classnames';

const messages = defineMessages({
  short_start: { id: 'navigation_bar.short.getting_started', defaultMessage: 'Started' },
  short_home_timeline: { id: 'navigation_bar.short.home', defaultMessage: 'Home' },
  short_notifications: { id: 'navigation_bar.short.notifications', defaultMessage: 'Notif.' },
  short_public: { id: 'navigation_bar.short.public_timeline', defaultMessage: 'FTL' },
  short_community: { id: 'navigation_bar.short.community_timeline', defaultMessage: 'LTL' },
  short_lists: { id: 'navigation_bar.short.lists', defaultMessage: 'Lists' },
  short_preferences: { id: 'navigation_bar.short.preferences', defaultMessage: 'Pref.' },
  short_logout: { id: 'navigation_bar.short.logout', defaultMessage: 'Logout' },
  start: { id: 'getting_started.heading', defaultMessage: 'Getting started' },
  home_timeline: { id: 'tabs_bar.home', defaultMessage: 'Home' },
  notifications: { id: 'tabs_bar.notifications', defaultMessage: 'Notifications' },
  public: { id: 'navigation_bar.public_timeline', defaultMessage: 'Federated timeline' },
  lists: { id: 'navigation_bar.lists', defaultMessage: 'Lists' },
  preferences: { id: 'navigation_bar.preferences', defaultMessage: 'Preferences' },
  logout: { id: 'navigation_bar.logout', defaultMessage: 'Logout' },
  compose: { id: 'navigation_bar.compose', defaultMessage: 'Compose new toot' },
  logoutMessage: { id: 'confirmations.logout.message', defaultMessage: 'Are you sure you want to log out?' },
  logoutConfirm: { id: 'confirmations.logout.confirm', defaultMessage: 'Log out' },
});

const mapStateToProps = (state, ownProps) => ({
  columns: state.getIn(['settings', 'columns']),
  showSearch: ownProps.multiColumn ? state.getIn(['search', 'submitted']) && !state.getIn(['search', 'hidden']) : ownProps.isSearchPage,
});

export default @connect(mapStateToProps)
@injectIntl
class Compose extends React.PureComponent {

  static propTypes = {
    dispatch: PropTypes.func.isRequired,
    columns: ImmutablePropTypes.list.isRequired,
    multiColumn: PropTypes.bool,
    showSearch: PropTypes.bool,
    isSearchPage: PropTypes.bool,
    intl: PropTypes.object.isRequired,
  };

  componentDidMount () {
    const { isSearchPage } = this.props;

    if (!isSearchPage) {
      this.props.dispatch(mountCompose());
    }
  }

  componentWillUnmount () {
    const { isSearchPage } = this.props;

    if (!isSearchPage) {
      this.props.dispatch(unmountCompose());
    }
  }

  handleLogoutClick = e => {
    const { dispatch, intl } = this.props;

    e.preventDefault();
    e.stopPropagation();

    dispatch(openModal('CONFIRM', {
      message: intl.formatMessage(messages.logoutMessage),
      confirm: intl.formatMessage(messages.logoutConfirm),
      onConfirm: () => logOut(),
    }));

    return false;
  }

  onFocus = () => {
    this.props.dispatch(changeComposing(true));
  }

  onBlur = () => {
    this.props.dispatch(changeComposing(false));
  }

  tab (id) {
    const { columns, intl: { formatMessage } } = this.props;

    if (!columns.some(column => column.get('id') === id)) {
      const tabParams = {
        'START':         { to: '/getting-started',        title: formatMessage(messages.start),         label: formatMessage(messages.short_start),         icon_id: 'bars' },
        'HOME':          { to: '/timelines/home',         title: formatMessage(messages.home_timeline), label: formatMessage(messages.short_home_timeline), icon_id: 'home' },
        'NOTIFICATIONS': { to: '/notifications',          title: formatMessage(messages.notifications), label: formatMessage(messages.short_notifications), icon_id: 'bell' },
        // 'COMMUNITY':     { to: '/timelines/public/local', title: formatMessage(messages.community),     label: formatMessage(messages.short_community),     icon_id: 'users' },
        'PUBLIC':        { to: '/timelines/public',       title: formatMessage(messages.public),        label: formatMessage(messages.short_public),        icon_id: 'globe' },
        'LIST':          { to: '/lists',                  title: formatMessage(messages.lists),         label: formatMessage(messages.short_lists),         icon_id: 'list-ul' },
        'PREFERENCES':   { href: '/settings/preferences', title: formatMessage(messages.preferences),   label: formatMessage(messages.short_preferences),   icon_id: 'cog' },
        'SIGN_OUT':      { href: '/auth/sign_out',        title: formatMessage(messages.logout),        label: formatMessage(messages.short_logout),        icon_id: 'sign-out', method: 'delete' },
      };

      const { href, to, title, label, icon_id, method } = tabParams[id];

      const icon = (id === 'NOTIFICATIONS') ? <NotificationsCounterIcon /> : <Icon id={icon_id} fixedWidth />;

      if (href) {
        return (
          <a href={href} className={classNames('drawer__tab', { 'short-label': show_tab_bar_label })} title={title} aria-label={title} data-method={method}>{icon}<span className='drawer__tab__short-label'>{label}</span></a>
        );
      } else {
        return (
          <Link to={to} className={classNames('drawer__tab', { 'short-label': show_tab_bar_label })} title={title} aria-label={title}>{icon}<span className='drawer__tab__short-label'>{label}</span></Link>
        );
      }
    }
    return null;
  }

  render () {
    const { multiColumn, showSearch, isSearchPage, intl } = this.props;

    let header = '';

    if (multiColumn) {
      // const defaultTabIds = ['START', 'HOME', 'NOTIFICATIONS', 'COMMUNITY', 'PUBLIC', 'LIST', 'PREFERENCES', 'SIGN_OUT'];
      const defaultTabIds = ['START', 'HOME', 'NOTIFICATIONS', 'PUBLIC', 'LIST', 'PREFERENCES', 'SIGN_OUT'];

      let tabs = defaultTabIds;

      header = (
        <nav className='drawer__header'>
          {tabs.map(tabId => (
            <Fragment key={tabId}>{this.tab(tabId)}</Fragment>
          ))}
        </nav>
      );
    }

    return (
      <div className='drawer' role='region' aria-label={intl.formatMessage(messages.compose)}>
        {header}

        {(multiColumn || isSearchPage) && <SearchContainer /> }

        <div className='drawer__pager'>
          {!isSearchPage && <div className='drawer__inner' onFocus={this.onFocus}>
            <NavigationContainer onClose={this.onBlur} />

            <ComposeFormContainer />

            <div className='drawer__inner__mastodon'>
              <img alt='' draggable='false' src={mascot || elephantUIPlane} />
            </div>
          </div>}

          <Motion defaultStyle={{ x: isSearchPage ? 0 : -100 }} style={{ x: spring(showSearch || isSearchPage ? 0 : -100, { stiffness: 210, damping: 20 }) }}>
            {({ x }) => (
              <div className='drawer__inner darker' style={{ transform: `translateX(${x}%)`, visibility: x === -100 ? 'hidden' : 'visible' }}>
                <SearchResultsContainer />
              </div>
            )}
          </Motion>
        </div>
      </div>
    );
  }

}
