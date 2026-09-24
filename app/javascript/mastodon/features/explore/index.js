import React, { PureComponent } from 'react';
import PropTypes from 'prop-types';
import { defineMessages, injectIntl, FormattedMessage } from 'react-intl';
import { Helmet } from 'react-helmet';
import { NavLink, Switch, Route } from 'react-router-dom';

import Column from 'mastodon/components/column';
import ColumnHeader from 'mastodon/components/column_header';

import Links from './links';
import Statuses from './statuses';
import Suggestions from './suggestions';
import Tags from './tags';

const messages = defineMessages({
  title: { id: 'explore.title', defaultMessage: 'Explore' },
});

export default @injectIntl
class Explore extends PureComponent {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    multiColumn: PropTypes.bool,
  };

  handleHeaderClick = () => {
    this.column.scrollTop();
  };

  setRef = c => {
    this.column = c;
  };

  render () {
    const { intl, multiColumn } = this.props;

    return (
      <Column bindToDocument={!multiColumn} ref={this.setRef} label={intl.formatMessage(messages.title)}>
        <ColumnHeader
          icon='hashtag'
          title={intl.formatMessage(messages.title)}
          onClick={this.handleHeaderClick}
          multiColumn={multiColumn}
          showBackButton
        />

        <div className='account__section-headline'>
          <NavLink exact to='/explore' isActive={(match, location) => ['/explore', '/explore/posts'].includes(location.pathname)}>
            <FormattedMessage tagName='div' id='explore.trending_statuses' defaultMessage='Posts' />
          </NavLink>

          <NavLink exact to='/explore/tags'>
            <FormattedMessage tagName='div' id='explore.trending_tags' defaultMessage='Hashtags' />
          </NavLink>

          <NavLink exact to='/explore/suggestions'>
            <FormattedMessage tagName='div' id='explore.suggested_follows' defaultMessage='People' />
          </NavLink>

          <NavLink exact to='/explore/links'>
            <FormattedMessage tagName='div' id='explore.trending_links' defaultMessage='News' />
          </NavLink>
        </div>

        <Switch>
          <Route path='/explore/tags' component={Tags} />
          <Route path='/explore/links' component={Links} />
          <Route path='/explore/suggestions' component={Suggestions} />
          <Route exact path={['/explore', '/explore/posts']}>
            <Statuses multiColumn={multiColumn} />
          </Route>
        </Switch>

        <Helmet>
          <title>{intl.formatMessage(messages.title)}</title>
        </Helmet>
      </Column>
    );
  }

}
