import React from 'react';
import PropTypes from 'prop-types';
import { NavLink, withRouter } from 'react-router-dom';
import { FormattedMessage, injectIntl } from 'react-intl';
import { debounce, memoize } from 'lodash';
import { isUserTouching } from '../../../is_mobile';
import Icon from 'mastodon/components/icon';
import NotificationsCounterIcon from './notifications_counter_icon';
import { place_tab_bar_at_bottom, show_tab_bar_label, enable_limited_timeline } from 'mastodon/initial_state';
import classNames from 'classnames';

const links = [
  <NavLink className='tabs-bar__link' to='/timelines/home' data-preview-title-id='column.home' data-preview-icon='home' ><Icon id='home' fixedWidth /><span className='tabs-bar__link__full-label'><FormattedMessage id='tabs_bar.home' defaultMessage='Home' /></span><span className='tabs-bar__link__short-label'><FormattedMessage id='navigation_bar.short.home' defaultMessage='Home' /></span></NavLink>,
  <NavLink className='tabs-bar__link tabs-bar__limited' to='/timelines/limited' data-preview-title-id='column.limited' data-preview-icon='lock' ><Icon id='lock' fixedWidth /><span className='tabs-bar__link__full-label'><FormattedMessage id='tabs_bar.limited_timeline' defaultMessage='Limited' /></span><span className='tabs-bar__link__short-label'><FormattedMessage id='navigation_bar.short.limited_timeline' defaultMessage='Ltd.' /></span></NavLink>,
  <NavLink className='tabs-bar__link' to='/notifications' data-preview-title-id='column.notifications' data-preview-icon='bell' ><NotificationsCounterIcon /><span className='tabs-bar__link__full-label'><FormattedMessage id='tabs_bar.notifications' defaultMessage='Notifications' /></span><span className='tabs-bar__link__short-label'><FormattedMessage id='navigation_bar.short.notifications' defaultMessage='Notif.' /></span></NavLink>,
  <NavLink className='tabs-bar__link' exact to='/timelines/public' data-preview-title-id='column.public' data-preview-icon='globe' ><Icon id='globe' fixedWidth /><span className='tabs-bar__link__full-label'><FormattedMessage id='tabs_bar.federated_timeline' defaultMessage='Federated' /></span><span className='tabs-bar__link__short-label'><FormattedMessage id='navigation_bar.short.public_timeline' defaultMessage='FTL' /></span></NavLink>,
  <NavLink className='tabs-bar__link' exact to='/lists' data-preview-title-id='column.lists' data-preview-icon='list-ul' ><Icon id='list-ul' fixedWidth /><span className='tabs-bar__link__full-label'><FormattedMessage id='tabs_bar.lists' defaultMessage='Lists' /></span><span className='tabs-bar__link__short-label'><FormattedMessage id='navigation_bar.short.lists' defaultMessage='List' /></span></NavLink>,
  <NavLink className='tabs-bar__link optional' to='/search' data-preview-title-id='tabs_bar.search' data-preview-icon='bell' ><Icon id='search' fixedWidth /><span className='tabs-bar__link__full-label'><FormattedMessage id='tabs_bar.search' defaultMessage='Search' /></span><span className='tabs-bar__link__short-label'><FormattedMessage id='navigation_bar.short.search' defaultMessage='Search' /></span></NavLink>,
  // <a className='tabs-bar__external-link' href='/settings/preferences' to='/settings/preferences' data-preview-title-id='navigation_bar.preferences' data-preview-icon='cog' ><Icon id='cog' fixedWidth /><span className='tabs-bar__link__full-label'><FormattedMessage id='navigation_bar.preferences' defaultMessage='Preferences' /></span><span className='tabs-bar__link__short-label'><FormattedMessage id='navigation_bar.short.preferences' defaultMessage='Pref.' /></span></a>,
  // <a className='tabs-bar__external-link' href='/auth/sign_out' to='/auth/sign_out' data-method='delete' data-preview-title-id='navigation_bar.logout' data-preview-icon='sign-out' ><Icon id='sign-out' fixedWidth /><span className='tabs-bar__link__full-label'><FormattedMessage id='navigation_bar.logout' defaultMessage='Logout' /></span><span className='tabs-bar__link__short-label'><FormattedMessage id='navigation_bar.short.logout' defaultMessage='Logout' /></span></a>,
  <NavLink className='tabs-bar__link hamburger' to='/getting-started' data-preview-title-id='getting_started.heading' data-preview-icon='bars' ><Icon id='bars' fixedWidth /></NavLink>,
];

export const getLinks = memoize(() => {
  return links.filter(link => {
    const classes = link.props.className.split(/\s+/);
    return !(!enable_limited_timeline && classes.includes('tabs-bar__limited'));
  });
});

export const getSwipeableLinks = memoize(() => {
  return getLinks().filter(link => {
    const classes = link.props.className.split(/\s+/);
    return classes.includes('tabs-bar__link');
  });
});

export function getSwipeableIndex (path) {
  return getSwipeableLinks().findIndex(link => link.props.to === path);
}

export function getSwipeableLink (index) {
  return getSwipeableLinks()[index].props.to;
}

export function getIndex (path) {
  return getLinks().findIndex(link => link.props.to === path);
}

export function getLink (index) {
  return getLinks()[index].props.to;
}

export default @injectIntl
@withRouter
class TabsBar extends React.PureComponent {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    history: PropTypes.object.isRequired,
  };

  setRef = ref => {
    this.node = ref;
  }

  handleClick = (e) => {
    // Only apply optimization for touch devices, which we assume are slower
    // We thus avoid the 250ms delay for non-touch devices and the lag for touch devices
    if (isUserTouching()) {
      e.preventDefault();
      e.persist();

      requestAnimationFrame(() => {
        const tabs = Array(...this.node.querySelectorAll('.tabs-bar__link'));
        const currentTab = tabs.find(tab => tab.classList.contains('active'));
        const nextTab = tabs.find(tab => tab.contains(e.target));
        const { props: { to } } = getLinks()[Array(...this.node.childNodes).indexOf(nextTab)];


        if (currentTab !== nextTab) {
          if (currentTab) {
            currentTab.classList.remove('active');
          }

          const listener = debounce(() => {
            nextTab.removeEventListener('transitionend', listener);
            this.props.history.push(to);
          }, 50);

          nextTab.addEventListener('transitionend', listener);
          nextTab.classList.add('active');
        }
      });
    }

  }

  render () {
    const { intl: { formatMessage } } = this.props;

    return (
      <div className='tabs-bar__wrapper'>
        <nav className={classNames('tabs-bar', { 'bottom-bar': place_tab_bar_at_bottom })} ref={this.setRef}>
          {getLinks().map(link => React.cloneElement(link, { key: link.props.to, className: classNames(link.props.className, { 'short-label': show_tab_bar_label }), onClick: link.props.href ? null : this.handleClick, 'aria-label': formatMessage({ id: link.props['data-preview-title-id'] }) }))}
        </nav>

        <div id='tabs-bar__portal' />
      </div>
    );
  }

}
