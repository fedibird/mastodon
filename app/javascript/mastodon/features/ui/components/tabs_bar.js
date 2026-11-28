import React from 'react';
import PropTypes from 'prop-types';
import { NavLink, withRouter } from 'react-router-dom';
import { defineMessages, FormattedMessage, injectIntl } from 'react-intl';
import { debounce, memoize } from 'lodash';
import { isUserTouching } from '../../../is_mobile';
import Icon from 'mastodon/components/icon';
import NotificationsCounterIcon from './notifications_counter_icon';
import { place_tab_bar_at_bottom, show_tab_bar_label, enableLimitedTimeline, enableFederatedTimeline, enableLocalTimeline, enablePersonalTimeline } from 'mastodon/initial_state';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { connect } from 'react-redux';
import { createSelector } from 'reselect';
import classNames from 'classnames';
import { EmojiMutedPlain, withEmojiMuteTextIndex } from 'mastodon/components/emoji_muted_html';
import { forgetEmojiMuteAttributeSource, rememberEmojiMuteAttributeSource } from 'mastodon/features/emoji/emoji_mute_sources';
import { emojiMutedPlainText } from 'mastodon/features/emoji/emoji_mute_text';

const messages = defineMessages({
  lists: { id: 'column.lists', defaultMessage: 'Lists' },
});

// The memoized NavLink stays the control record. The raw title stays in
// this map, not in a display attribute. Route id, path, and key do not use it.
const favouriteListTitles = new WeakMap();

const accessibleListName = (plain, index, emptyLabel) => {
  const projected = emojiMutedPlainText(typeof plain === 'string' ? plain : '', '', index);
  const visible = typeof projected === 'string' ? projected : '';

  return visible.trim() === '' ? emptyLabel : visible;
};

class FavouriteListLabelsInner extends React.PureComponent {

  static propTypes = {
    plain: PropTypes.string.isRequired,
    intl: PropTypes.object.isRequired,
    emojiMuteTextIndex: PropTypes.object,
  };

  componentDidMount() {
    this.bindHost();
  }

  componentDidUpdate() {
    this.bindHost();
  }

  componentWillUnmount() {
    this.releaseHost();
  }

  setNode = node => {
    this.node = node;
  };

  host() {
    return this.node && this.node.closest ? this.node.closest('a') : null;
  }

  bindHost() {
    const host = this.host();

    if (!host) {
      return;
    }

    const plain = this.props.plain;
    const emptyLabel = this.props.intl.formatMessage(messages.lists);
    const name = accessibleListName(plain, this.props.emojiMuteTextIndex, emptyLabel);

    if (host.getAttribute('aria-label') !== name) {
      host.setAttribute('aria-label', name);
    }

    if (host.getAttribute('data-preview-title') !== name) {
      host.setAttribute('data-preview-title', name);
    }

    rememberEmojiMuteAttributeSource(host, 'aria-label', plain, 'plain', emptyLabel, true);
    rememberEmojiMuteAttributeSource(host, 'data-preview-title', plain, 'plain', emptyLabel, true);
  }

  releaseHost() {
    const host = this.host();

    if (!host) {
      return;
    }

    forgetEmojiMuteAttributeSource(host, 'aria-label');
    forgetEmojiMuteAttributeSource(host, 'data-preview-title');
  }

  render() {
    const { plain } = this.props;

    return (
      <React.Fragment>
        <span className='tabs-bar__link__full-label' ref={this.setNode}>
          <EmojiMutedPlain tag='span' plain={plain} html='' />
        </span>
        <span className='tabs-bar__link__short-label'>
          <EmojiMutedPlain tag='span' plain={plain} html='' />
        </span>
      </React.Fragment>
    );
  }

}

const FavouriteListLabels = withEmojiMuteTextIndex(injectIntl(FavouriteListLabelsInner));

export function swipeLoadingTitle(link, formatMessage) {
  if (!link || !link.props) {
    return '';
  }

  if (favouriteListTitles.has(link)) {
    return (
      <EmojiMutedPlain
        tag='span'
        plain={favouriteListTitles.get(link)}
        html=''
        emptyLabel={formatMessage(messages.lists)}
      />
    );
  }

  if (typeof link.props['data-preview-title'] === 'string') {
    return link.props['data-preview-title'];
  }

  const id = link.props['data-preview-title-id'];

  return typeof id === 'string' && id !== '' ? formatMessage({ id }) : '';
}

const link_home = <NavLink className='tabs-bar__link' to='/timelines/home' data-preview-title-id='column.home' data-preview-icon='home' ><Icon id='home' fixedWidth /><span className='tabs-bar__link__full-label'><FormattedMessage id='tabs_bar.home' defaultMessage='Home' children={msg=> <>{msg}</>} /></span><span className='tabs-bar__link__short-label'><FormattedMessage id='navigation_bar.short.home' defaultMessage='Home' children={msg=> <>{msg}</>} /></span></NavLink>;
const link_limited = <NavLink className='tabs-bar__link tabs-bar__limited' to='/timelines/limited' data-preview-title-id='column.limited' data-preview-icon='lock' ><Icon id='lock' fixedWidth /><span className='tabs-bar__link__full-label'><FormattedMessage id='tabs_bar.limited_timeline' defaultMessage='Limited' children={msg=> <>{msg}</>} /></span><span className='tabs-bar__link__short-label'><FormattedMessage id='navigation_bar.short.limited_timeline' defaultMessage='Ltd.' children={msg=> <>{msg}</>} /></span></NavLink>;
const link_personal = <NavLink className='tabs-bar__link tabs-bar__personal' to='/timelines/personal' data-preview-title-id='column.personal' data-preview-icon='book' ><Icon id='book' fixedWidth /><span className='tabs-bar__link__full-label'><FormattedMessage id='tabs_bar.personal_timeline' defaultMessage='Personal' children={msg=> <>{msg}</>} /></span><span className='tabs-bar__link__short-label'><FormattedMessage id='navigation_bar.short.personal_timeline' defaultMessage='Per.' children={msg=> <>{msg}</>} /></span></NavLink>;
const link_notifications = <NavLink className='tabs-bar__link' to='/notifications' data-preview-title-id='column.notifications' data-preview-icon='bell' ><NotificationsCounterIcon /><span className='tabs-bar__link__full-label'><FormattedMessage id='tabs_bar.notifications' defaultMessage='Notifications' children={msg=> <>{msg}</>} /></span><span className='tabs-bar__link__short-label'><FormattedMessage id='navigation_bar.short.notifications' defaultMessage='Notif.' children={msg=> <>{msg}</>} /></span></NavLink>;
const link_local = <NavLink className='tabs-bar__link' exact to='/timelines/public/local' data-preview-title-id='column.community' data-preview-icon='users' ><Icon id='users' fixedWidth /><span className='tabs-bar__link__full-label'><FormattedMessage id='tabs_bar.local_timeline' defaultMessage='Local' children={msg=> <>{msg}</>} /></span><span className='tabs-bar__link__short-label'><FormattedMessage id='navigation_bar.short.local_timeline' defaultMessage='LTL' children={msg=> <>{msg}</>} /></span></NavLink>;
const link_public = <NavLink className='tabs-bar__link' exact to='/timelines/public' data-preview-title-id='column.public' data-preview-icon='globe' ><Icon id='globe' fixedWidth /><span className='tabs-bar__link__full-label'><FormattedMessage id='tabs_bar.federated_timeline' defaultMessage='Federated' children={msg=> <>{msg}</>} /></span><span className='tabs-bar__link__short-label'><FormattedMessage id='navigation_bar.short.public_timeline' defaultMessage='FTL' children={msg=> <>{msg}</>} /></span></NavLink>;
// const link_lists = <NavLink className='tabs-bar__link' exact to='/lists' data-preview-title-id='column.lists' data-preview-icon='list-ul' ><Icon id='list-ul' fixedWidth /><span className='tabs-bar__link__full-label'><FormattedMessage id='tabs_bar.lists' defaultMessage='Lists' children={msg=> <>{msg}</>} /></span><span className='tabs-bar__link__short-label'><FormattedMessage id='navigation_bar.short.lists' defaultMessage='List' children={msg=> <>{msg}</>} /></span></NavLink>;
const link_search = <NavLink className='tabs-bar__link optional' to='/search' data-preview-title-id='tabs_bar.search' data-preview-icon='bell' ><Icon id='search' fixedWidth /><span className='tabs-bar__link__full-label'><FormattedMessage id='tabs_bar.search' defaultMessage='Search' children={msg=> <>{msg}</>} /></span><span className='tabs-bar__link__short-label'><FormattedMessage id='navigation_bar.short.search' defaultMessage='Search' children={msg=> <>{msg}</>} /></span></NavLink>;
// const link_preferences = <a className='tabs-bar__external-link' href='/settings/preferences' to='/settings/preferences' data-preview-title-id='navigation_bar.preferences' data-preview-icon='cog' ><Icon id='cog' fixedWidth /><span className='tabs-bar__link__full-label'><FormattedMessage id='navigation_bar.preferences' defaultMessage='Preferences' children={msg=> <>{msg}</>} /></span><span className='tabs-bar__link__short-label'><FormattedMessage id='navigation_bar.short.preferences' defaultMessage='Pref.' children={msg=> <>{msg}</>} /></span></a>;
// const link_sign_out = <a className='tabs-bar__external-link' href='/auth/sign_out' to='/auth/sign_out' data-method='delete' data-preview-title-id='navigation_bar.logout' data-preview-icon='sign-out' ><Icon id='sign-out' fixedWidth /><span className='tabs-bar__link__full-label'><FormattedMessage id='navigation_bar.logout' defaultMessage='Logout' children={msg=> <>{msg}</>} /></span><span className='tabs-bar__link__short-label'><FormattedMessage id='navigation_bar.short.logout' defaultMessage='Logout' children={msg=> <>{msg}</>} /></span></a>;
const link_started = <NavLink className='tabs-bar__link hamburger' to='/getting-started' data-preview-title-id='getting_started.heading' data-preview-icon='bars' ><Icon id='bars' fixedWidth /></NavLink>;

export const getLinks = memoize((favouriteLists = null) => {
  const link_favourite_lists = favouriteLists ? favouriteLists.map(list => {
    if (!list.get('favourite')) {
      return null;
    }

    const title = list.get('title');
    const plain = typeof title === 'string' ? title : '';
    const link = (
      <NavLink className='tabs-bar__link' exact to={`/timelines/list/${list.get('id')}`} data-preview-title-id={`list/${list.get('id')}`} data-preview-icon='list-ul' >
        <Icon id='list-ul' fixedWidth />
        <FavouriteListLabels plain={plain} />
      </NavLink>
    );

    favouriteListTitles.set(link, plain);
    return link;
  }).toArray() : null;

  return [
    link_home,
    enableLimitedTimeline ? link_limited : null,
    enablePersonalTimeline ? link_personal : null,
    link_favourite_lists,
    link_notifications,
    enableLocalTimeline ? link_local : null,
    enableFederatedTimeline ? link_public : null,
    link_search,
    link_started,
  ].flat().filter(v => !!v);
});

export const getSwipeableLinks = memoize((favouriteLists = null) => {
  return getLinks(favouriteLists).filter(link => {
    const classes = link.props.className.split(/\s+/);
    return classes.includes('tabs-bar__link');
  });
});

export function getSwipeableIndex (favouriteLists = null, path) {
  return getSwipeableLinks(favouriteLists).findIndex(link => link.props.to === path);
}

export function getSwipeableLink (favouriteLists = null, index) {
  return getSwipeableLinks(favouriteLists)[index].props.to;
}

export function getIndex (favouriteLists = null, path) {
  return getLinks(favouriteLists).findIndex(link => link.props.to === path);
}

export function getLink (favouriteLists = null, index) {
  return getLinks(favouriteLists)[index].props.to;
}

export const getFavouriteOrderedLists = createSelector([state => state.get('lists')], lists => {
  if (!lists) {
    return lists;
  }

  return lists.toList().filter(item => !!item && item.get('favourite')).sort((a, b) => a.get('title').localeCompare(b.get('title')));
});

const mapStateToProps = state => ({
  favouriteLists: getFavouriteOrderedLists(state),
});

export default @injectIntl
@withRouter
@connect(mapStateToProps)
class TabsBar extends React.PureComponent {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    history: PropTypes.object.isRequired,
    favouriteLists: ImmutablePropTypes.list,
  };

  setRef = ref => {
    this.node = ref;
  }

  handleClick = (e) => {
    const { favouriteLists } = this.props;

    // Only apply optimization for touch devices, which we assume are slower
    // We thus avoid the 250ms delay for non-touch devices and the lag for touch devices
    if (isUserTouching()) {
      e.preventDefault();
      e.persist();

      requestAnimationFrame(() => {
        const tabs = Array(...this.node.querySelectorAll('.tabs-bar__link'));
        const currentTab = tabs.find(tab => tab.classList.contains('active'));
        const nextTab = tabs.find(tab => tab.contains(e.target));
        const { props: { to } } = getLinks(favouriteLists)[Array(...this.node.childNodes).indexOf(nextTab)];


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
    const { intl: { formatMessage }, favouriteLists } = this.props;

    return (
      <div className='tabs-bar__wrapper'>
        <nav className={classNames('tabs-bar', { 'bottom-bar': place_tab_bar_at_bottom })} ref={this.setRef}>
          {getLinks(favouriteLists).map(link => {
            const props = {
              key: link.props.to,
              className: classNames(link.props.className, { 'short-label': show_tab_bar_label }),
              onClick: link.props.href ? null : this.handleClick,
            };

            // List tabs name themselves from the projected title. Their
            // data-preview-title-id is the route key, not a message id.
            if (!favouriteListTitles.has(link)) {
              props['aria-label'] = link.props['data-preview-title'] ?? formatMessage({ id: link.props['data-preview-title-id'] });
            }

            return React.cloneElement(link, props);
          })}
        </nav>

        <div id='tabs-bar__portal' />
      </div>
    );
  }

}
