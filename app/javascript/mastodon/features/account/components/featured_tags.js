import React from 'react';
import { connect } from 'react-redux';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import ImmutablePureComponent from 'react-immutable-pure-component';
import { defineMessages, injectIntl } from 'react-intl';
import classNames from 'classnames';
import Permalink from 'mastodon/components/permalink';
import ShortNumber from 'mastodon/components/short_number';
import { List as ImmutableList, Map as ImmutableMap } from 'immutable';

const messages = defineMessages({
  hashtag_all: { id: 'account.hashtag_all', defaultMessage: 'All' },
  hashtag_all_description: { id: 'account.hashtag_all_description', defaultMessage: 'All posts (deselect hashtags)' },
  hashtag_select_description: { id: 'account.hashtag_select_description', defaultMessage: 'Select hashtag #{name}' },
  statuses_counter: { id: 'account.statuses_counter', defaultMessage: '{count, plural, one {{counter} Post} other {{counter} Posts}}' },
});

// Current account tag pages are valid even if the tag is not featured.
// Append a display-only choice. Never mutate the account's featured tags.
export const displayedFeaturedTags = (featuredTags, tagged) => {
  const name = (tagged || '').replace(/^#/, '').trim();
  if (!name || featuredTags.some(tag => String(tag.get('name')).toLocaleLowerCase() === name.toLocaleLowerCase())) {
    return featuredTags;
  }

  return featuredTags.push(ImmutableMap({ name, temporary: true }));
};

const mapStateToProps = (state, { account }) => ({
  featuredTags: state.getIn(['user_lists', 'featured_tags', account.get('id'), 'items'], ImmutableList()),
});

export default @connect(mapStateToProps)
@injectIntl
class FeaturedTags extends ImmutablePureComponent {

  static contextTypes = {
    router: PropTypes.object,
  };

  static propTypes = {
    account: ImmutablePropTypes.map,
    featuredTags: ImmutablePropTypes.list,
    tagged: PropTypes.string,
    routeBase: PropTypes.string,
    onSelectTag: PropTypes.func,
    intl: PropTypes.object.isRequired,
  };

  handleChooseTag = tag => {
    this.props.onSelectTag?.(tag || null);
    // Permalink's interception avoids route changes in the media gallery.
    return true;
  }

  handleChooseAll = () => this.handleChooseTag(null);

  render () {
    const { account, featuredTags, tagged, intl, onSelectTag } = this.props;

    if (!account) {
      return null;
    }

    const displayed = displayedFeaturedTags(featuredTags, tagged);
    if (displayed.isEmpty() && !onSelectTag) {
      return null;
    }

    const suspended = account.get('suspended');
    const accountId = account.get('id');
    const routeBase = this.props.routeBase || `/accounts/${accountId}/posts`;
    const onChooseAll = onSelectTag ? this.handleChooseAll : undefined;

    return (
      <div className={classNames('account__header', 'advanced', { inactive: !!account.get('moved') })}>
        <div className='account__header__extra'>
          <div className='account__header__extra__hashtag-links'>
            <Permalink key='all' className={classNames('account__hashtag-link', { active: !tagged })} title={intl.formatMessage(messages.hashtag_all_description)} href={account.get('url')} to={routeBase} onInterceptClick={onChooseAll}>{intl.formatMessage(messages.hashtag_all)}</Permalink>
            {!suspended && displayed.map(featuredTag => {
              const name  = featuredTag.get('name');
              const url   = featuredTag.get('url');
              const to    = `${routeBase}/${encodeURIComponent(name)}`;
              const desc  = intl.formatMessage(messages.hashtag_select_description, { name });
              const count = featuredTag.get('statuses_count');
              const temporary = !!featuredTag.get('temporary');
              const active = !!tagged && tagged.toLocaleLowerCase() === name.toLocaleLowerCase();
              const onChooseTag = onSelectTag ? this.handleChooseTag.bind(this, name) : undefined;
              const countBadge = !temporary && count !== null && count !== undefined && <span title={intl.formatMessage(messages.statuses_counter, { count, counter: intl.formatNumber(count) })}>({<ShortNumber value={count} />})</span>;

              return (
                <Permalink key={`#${name}`} className={classNames('account__hashtag-link', { active, 'account__hashtag-link--temporary': temporary })} title={desc} href={url || account.get('url')} to={to} onInterceptClick={onChooseTag}>
                  #{name} {countBadge}
                </Permalink>
              );
            })}
          </div>
        </div>
      </div>
    );
  }

}
