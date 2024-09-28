import React from 'react';
import PropTypes from 'prop-types';
import { defineMessages, injectIntl, FormattedMessage } from 'react-intl';
import Icon from 'mastodon/components/icon';
import { enableReaction, enableStatusReference } from 'mastodon/initial_state';

const tooltips = defineMessages({
  mentions: { id: 'notifications.filter.mentions', defaultMessage: 'Mentions' },
  favourites: { id: 'notifications.filter.favourites', defaultMessage: 'Favourites' },
  boosts: { id: 'notifications.filter.boosts', defaultMessage: 'Boosts' },
  polls: { id: 'notifications.filter.polls', defaultMessage: 'Poll results' },
  follows: { id: 'notifications.filter.follows', defaultMessage: 'Follows' },
  followed: { id: 'notifications.filter.followed', defaultMessage: 'Followed message' },
  statuses: { id: 'notifications.filter.statuses', defaultMessage: 'Updates from people you follow' },
  reactions: { id: 'notifications.filter.emoji_reactions', defaultMessage: 'Reactions' },
  reference: { id: 'notifications.filter.status_references', defaultMessage: 'Status references' },
  scheduled_statuses: { id: 'notifications.filter.scheduled_statuses', defaultMessage: 'Scheduled statuses' },
});

export default @injectIntl
class FilterBar extends React.PureComponent {

  static propTypes = {
    selectFilter: PropTypes.func.isRequired,
    selectedFilter: PropTypes.string.isRequired,
    advancedMode: PropTypes.bool.isRequired,
    intl: PropTypes.object.isRequired,
  };

  onClick (notificationType) {
    return () => this.props.selectFilter(notificationType);
  }

  render () {
    const { selectedFilter, advancedMode, intl } = this.props;
    const renderedElement = !advancedMode ? (
      <div className='notification__filter-bar'>
        <button
          className={selectedFilter === 'all' ? 'active' : ''}
          onClick={this.onClick('all')}
        >
          <FormattedMessage
            id='notifications.filter.all'
            defaultMessage='All'
          />
        </button>
        <button
          className={selectedFilter === 'mention' ? 'active' : ''}
          onClick={this.onClick('mention')}
        >
          <FormattedMessage
            id='notifications.filter.mentions'
            defaultMessage='Mentions'
          />
        </button>
      </div>
    ) : (
      <div className='notification__filter-bar'>
        <button
          className={selectedFilter === 'all' ? 'active' : ''}
          onClick={this.onClick('all')}
        >
          <FormattedMessage
            id='notifications.filter.all'
            defaultMessage='All'
          />
        </button>
        <button
          className={selectedFilter === 'mention' ? 'active' : ''}
          onClick={this.onClick('mention')}
          title={intl.formatMessage(tooltips.mentions)}
        >
          <Icon id='reply-all' fixedWidth />
        </button>
        <button
          className={selectedFilter === 'favourite' ? 'active' : ''}
          onClick={this.onClick('favourite')}
          title={intl.formatMessage(tooltips.favourites)}
        >
          <Icon id='star' fixedWidth />
        </button>
        <button
          className={selectedFilter === 'reblog' ? 'active' : ''}
          onClick={this.onClick('reblog')}
          title={intl.formatMessage(tooltips.boosts)}
        >
          <Icon id='retweet' fixedWidth />
        </button>
        <button
          className={selectedFilter === 'poll' ? 'active' : ''}
          onClick={this.onClick('poll')}
          title={intl.formatMessage(tooltips.polls)}
        >
          <Icon id='tasks' fixedWidth />
        </button>
        <button
          className={selectedFilter === 'status' ? 'active' : ''}
          onClick={this.onClick('status')}
          title={intl.formatMessage(tooltips.statuses)}
        >
          <Icon id='home' fixedWidth />
        </button>
        <button
          className={selectedFilter === 'scheduled_status' ? 'active' : ''}
          onClick={this.onClick('scheduled_status')}
          title={intl.formatMessage(tooltips.scheduled_statuses)}
        >
          <Icon id='clock-o' fixedWidth />
        </button>
        {enableReaction &&
          <button
            className={selectedFilter === 'emoji_reaction' ? 'active' : ''}
            onClick={this.onClick('emoji_reaction')}
            title={intl.formatMessage(tooltips.reactions)}
          >
            <Icon id='smile-o' fixedWidth />
          </button>
        }
        {enableStatusReference &&
          <button
            className={selectedFilter === 'status_reference' ? 'active' : ''}
            onClick={this.onClick('status_reference')}
            title={intl.formatMessage(tooltips.reference)}
          >
            <Icon id='link' fixedWidth />
          </button>
        }
        <button
          className={selectedFilter === 'follow' ? 'active' : ''}
          onClick={this.onClick('follow')}
          title={intl.formatMessage(tooltips.follows)}
        >
          <Icon id='user-plus' fixedWidth />
        </button>
        <button
          className={selectedFilter === 'followed' ? 'active' : ''}
          onClick={this.onClick('followed')}
          title={intl.formatMessage(tooltips.followed)}
        >
          <Icon id='check-circle-o' fixedWidth />
        </button>
      </div>
    );
    return renderedElement;
  }

}
