import React, { Fragment } from 'react';
import ImmutablePropTypes from 'react-immutable-proptypes';
import PropTypes from 'prop-types';
import InnerHeader from '../../account/components/header';
import InnerHeaderCommon from '../../account/components/header_common';
import InnerHeaderExtra from '../../account/components/header_extra';
import InnerHeaderExtraLinks from '../../account/components/header_extra_links';
import FeaturedTags from '../../account/components/featured_tags';
import ImmutablePureComponent from 'react-immutable-pure-component';
import { follow_button_to_list_adder } from 'mastodon/initial_state';
import MovedNote from './moved_note';
import { FormattedMessage } from 'react-intl';
import { NavLink } from 'react-router-dom';
import Icon from 'mastodon/components/icon';

export default class Header extends ImmutablePureComponent {

  static propTypes = {
    account: ImmutablePropTypes.map,
    identity_proofs: ImmutablePropTypes.list,
    onFollow: PropTypes.func.isRequired,
    onSubscribe: PropTypes.func.isRequired,
    onAddToList: PropTypes.func.isRequired,
    onBlock: PropTypes.func.isRequired,
    onMention: PropTypes.func.isRequired,
    onDirect: PropTypes.func.isRequired,
    onConversations: PropTypes.func.isRequired,
    onReblogToggle: PropTypes.func.isRequired,
    onReport: PropTypes.func.isRequired,
    onMute: PropTypes.func.isRequired,
    onBlockDomain: PropTypes.func.isRequired,
    onUnblockDomain: PropTypes.func.isRequired,
    onEndorseToggle: PropTypes.func.isRequired,
    onAddToList: PropTypes.func.isRequired,
    onAddToCircle: PropTypes.func.isRequired,
    hideRelation: PropTypes.bool,
    hideProfile: PropTypes.bool,
    advancedMode: PropTypes.bool,
    tagged: PropTypes.string,
    hideFeaturedTags: PropTypes.bool,
    domain: PropTypes.string.isRequired,
  };

  static defaultProps = {
    hideProfile: false,
  };

  static contextTypes = {
    router: PropTypes.object,
  };

  handleFollow = (e) => {
    if ((e && e.shiftKey) ^ !follow_button_to_list_adder) {
      this.props.onFollow(this.props.account);
    } else {
      this.props.onAddToList(this.props.account);
    }
  }

  handleSubscribe = (e) => {
    if ((e && e.shiftKey) ^ !follow_button_to_list_adder) {
      this.props.onSubscribe(this.props.account);
    } else {
      this.props.onAddToList(this.props.account);
    }
  }

  handleBlock = () => {
    this.props.onBlock(this.props.account);
  }

  handleMention = () => {
    this.props.onMention(this.props.account, this.context.router.history);
  }

  handleDirect = () => {
    this.props.onDirect(this.props.account, this.context.router.history);
  }

  handleConversations = () => {
    this.props.onConversations(this.props.account, this.context.router.history);
  }

  handleReport = () => {
    this.props.onReport(this.props.account);
  }

  handleReblogToggle = () => {
    this.props.onReblogToggle(this.props.account);
  }

  handleMute = () => {
    this.props.onMute(this.props.account);
  }

  handleBlockDomain = () => {
    const domain = this.props.account.get('acct').split('@')[1];

    if (!domain) return;

    this.props.onBlockDomain(domain);
  }

  handleUnblockDomain = () => {
    const domain = this.props.account.get('acct').split('@')[1];

    if (!domain) return;

    this.props.onUnblockDomain(domain);
  }

  handleEndorseToggle = () => {
    this.props.onEndorseToggle(this.props.account);
  }

  handleAddToList = () => {
    this.props.onAddToList(this.props.account);
  }

  handleAddToCircle = () => {
    this.props.onAddToCircle(this.props.account);
  }

  handleEditAccountNote = () => {
    this.props.onEditAccountNote(this.props.account);
  }

  render () {
    const { account, hideRelation, identity_proofs, hideProfile, advancedMode, tagged, hideFeaturedTags } = this.props;

    if (account === null) {
      return null;
    }

    return (
      <div className='account-timeline__header'>
        {account.get('moved') && <MovedNote from={account} to={account.get('moved')} />}

        {advancedMode ? (
          <Fragment>
            <InnerHeaderCommon
              account={account}
              onFollow={this.handleFollow}
              onSubscribe={this.handleSubscribe}
              onBlock={this.handleBlock}
              onMention={this.handleMention}
              onDirect={this.handleDirect}
              onConversations={this.handleConversations}
              onReblogToggle={this.handleReblogToggle}
              onReport={this.handleReport}
              onMute={this.handleMute}
              onBlockDomain={this.handleBlockDomain}
              onUnblockDomain={this.handleUnblockDomain}
              onEndorseToggle={this.handleEndorseToggle}
              onAddToList={this.handleAddToList}
              onAddToCircle={this.handleAddToCircle}
              onEditAccountNote={this.handleEditAccountNote}
              domain={this.props.domain}
            />

            <div className='account__section-headline with-short-label'>
              <NavLink exact to={`/accounts/${account.get('id')}/posts`}><Icon id='home' fixedWidth /><span className='account__section-headline__short-label'><FormattedMessage id='account.short.posts' defaultMessage='Posts' children={msg=> <>{msg}</>} /></span></NavLink>
              <NavLink exact to={`/accounts/${account.get('id')}/with_replies`}><Icon id='reply-all' fixedWidth /><span className='account__section-headline__short-label'><FormattedMessage id='account.short.with_replies' defaultMessage='Posts & Replies' children={msg=> <>{msg}</>} /></span></NavLink>
              <NavLink exact to={`/accounts/${account.get('id')}/media`}><Icon id='picture-o' fixedWidth /><span className='account__section-headline__short-label'><FormattedMessage id='account.short.media' defaultMessage='Media' children={msg=> <>{msg}</>} /></span></NavLink>
              <NavLink exact to={`/accounts/${account.get('id')}/conversations`}><Icon id='at' fixedWidth /><span className='account__section-headline__short-label'><FormattedMessage id='account.short.conversations' defaultMessage='Conversations' children={msg=> <>{msg}</>} /></span></NavLink>
              <NavLink exact to={`/accounts/${account.get('id')}/about`}><Icon id='address-card-o' fixedWidth /><span className='account__section-headline__short-label'><FormattedMessage id='account.short.about' defaultMessage='About' children={msg=> <>{msg}</>} /></span></NavLink>
            </div>

            {!hideFeaturedTags && <FeaturedTags account={account} tagged={tagged} />}
            {!hideRelation && <InnerHeaderExtraLinks account={account} />}
            {!hideProfile && <InnerHeaderExtra account={account} identity_proofs={identity_proofs} />}
          </Fragment>
        ) : (
          <Fragment>
            <InnerHeader
              account={account}
              identity_proofs={identity_proofs}
              onFollow={this.handleFollow}
              onSubscribe={this.handleSubscribe}
              onBlock={this.handleBlock}
              onMention={this.handleMention}
              onDirect={this.handleDirect}
              onConversations={this.handleConversations}
              onReblogToggle={this.handleReblogToggle}
              onReport={this.handleReport}
              onMute={this.handleMute}
              onBlockDomain={this.handleBlockDomain}
              onUnblockDomain={this.handleUnblockDomain}
              onEndorseToggle={this.handleEndorseToggle}
              onAddToList={this.handleAddToList}
              onAddToCircle={this.handleAddToCircle}
              onEditAccountNote={this.handleEditAccountNote}
              domain={this.props.domain}
              hideProfile={hideProfile}
            />

            <div className='account__section-headline'>
              <NavLink exact to={`/accounts/${account.get('id')}`}><FormattedMessage id='account.posts' defaultMessage='Toots' /></NavLink>
              <NavLink exact to={`/accounts/${account.get('id')}/with_replies`}><FormattedMessage id='account.posts_with_replies' defaultMessage='Toots and replies' /></NavLink>
              <NavLink exact to={`/accounts/${account.get('id')}/media`}><FormattedMessage id='account.media' defaultMessage='Media' /></NavLink>
            </div>
          </Fragment>
        )}
      </div>
    );
  }

}
