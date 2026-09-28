import React from 'react';
import ImmutablePropTypes from 'react-immutable-proptypes';
import PropTypes from 'prop-types';
import { injectIntl, defineMessages, FormattedMessage } from 'react-intl';
import { connect } from 'react-redux';
import Permalink from './permalink';
import classnames from 'classnames';
import PollContainer from 'mastodon/containers/poll_container';
import Icon from 'mastodon/components/icon';
import BilingualContent from 'mastodon/components/bilingual_content';
import TranslationBar from 'mastodon/components/translation_bar';
import { setStatusTranslationAssumption } from 'mastodon/actions/statuses';
import { autoPlayEmoji, disableReactions, me, showTranslationBar, translationPreferredMode, translationPrivateContentAllowed } from 'mastodon/initial_state';
import { legacyTranslationPair, normalizedContentLocale, sameLanguagePair, statusTranslationView, viewerTranslationPair } from 'mastodon/utils/translation_view';

const messages = defineMessages({
  linkToAcct: { id: 'status.link_to_acct', defaultMessage: 'Link to @{acct}' },
  linkToCustomEmojiInLocal: { id: 'status.link_to_custom_emoji_in_local', defaultMessage: 'Link to :@{shortcode}:' },
  linkToCustomEmojiInRemote: { id: 'status.link_to_custom_emoji_in_remote', defaultMessage: 'Link to :@{shortcode}: in @{domain}' },
  postByAcct: { id: 'status.post_by_acct', defaultMessage: 'Post by @{acct}' },
});

const CHINESE_REGIONAL_SCRIPTS = {
  'zh-cn': 'zh-Hans',
  'zh-sg': 'zh-Hans',
  'zh-tw': 'zh-Hant',
  'zh-hk': 'zh-Hant',
  'zh-mo': 'zh-Hant',
};

const CHINESE_SCRIPT_TAGS = ['zh-Hans', 'zh-Hant'];

const normalizedLanguageTag = language => language.replace(/_/g, '-').toLowerCase();

const providerChineseScript = (normalized, translationLanguages) => (
  CHINESE_SCRIPT_TAGS.find(tag => tag.toLowerCase() === normalized && translationLanguages?.has(tag))
);

const bareChineseSourceLanguage = (language, translationLanguages) => {
  if (translationLanguages?.has('zh')) {
    return 'zh';
  }

  const chineseAvailable = CHINESE_SCRIPT_TAGS.some(tag => translationLanguages?.has(tag));
  if (chineseAvailable && translationLanguages?.has('und')) {
    return 'und';
  }

  return language;
};

const translationSourceLanguage = (language, translationLanguages) => {
  if (!language || translationLanguages?.has(language)) {
    return language;
  }

  const normalized = normalizedLanguageTag(language);

  if (normalized === 'zh') {
    return bareChineseSourceLanguage(language, translationLanguages);
  }

  const script = providerChineseScript(normalized, translationLanguages) || CHINESE_REGIONAL_SCRIPTS[normalized];
  if (script && translationLanguages?.has(script)) {
    return script;
  }

  const match = language.match(/^([A-Za-z]{2,3})[-_]([A-Za-z]{2}|\d{3})$/);
  if (!match) {
    return language;
  }

  const primary = match[1].toLowerCase();
  return translationLanguages?.has(primary) ? primary : language;
};

const statusTranslationEligible = (status, { loggedIn, contentLocale, targetLanguages, privateContentAllowed }) => {
  const visibilityAllowsTranslation = ['public', 'unlisted'].includes(status.get('visibility')) || privateContentAllowed;

  return loggedIn &&
    visibilityAllowsTranslation &&
    (status.get('search_index') || '').trim().length > 0 &&
    targetLanguages?.includes(contentLocale);
};

const MAX_HEIGHT = 642; // 20px * 32 (+ 2px padding at the top)

const mapStateToProps = (state, ownProps) => ({
  languages: state.getIn(['server', 'translationLanguages', 'items']),
  translationAssumption: state.getIn(['translation_assumptions', ownProps.status.get('id')]),
});

const mapDispatchToProps = dispatch => ({
  onTranslationAssumption(id, source, target) {
    dispatch(setStatusTranslationAssumption(id, source, target));
  },
});

class StatusContent extends React.PureComponent {

  static contextTypes = {
    router: PropTypes.object,
  };

  static propTypes = {
    status: ImmutablePropTypes.map.isRequired,
    expanded: PropTypes.bool,
    showThread: PropTypes.bool,
    onExpandedToggle: PropTypes.func,
    onClick: PropTypes.func,
    onTranslate: PropTypes.func,
    translationPreferredMode: PropTypes.string,
    collapsable: PropTypes.bool,
    onCollapsedToggle: PropTypes.func,
    quote: PropTypes.bool,
    languages: ImmutablePropTypes.map,
    translationAssumption: ImmutablePropTypes.map,
    onTranslationAssumption: PropTypes.func,
    intl: PropTypes.object.isRequired,
  };

  state = {
    hidden: true,
  };

  _updateEmojiLinks () {
    const node = this.node;

    if (!node) {
      return;
    }

    const emojis = node.querySelectorAll('.custom-emoji');

    for (var i = 0; i < emojis.length; i++) {
      let emoji = emojis[i];
      emoji.addEventListener('mouseup', this.handleEmojiMouseUp, false);
      emoji.addEventListener('click', this.handleEmojiClick, false);
      emoji.style.cursor = 'pointer';
    }
  }

  handleEmojiMouseUp = e => {
    e.preventDefault();
    e.stopPropagation();
  }

  handleEmojiClick = e => {
    const shortcode = e.target.dataset.shortcode;
    const domain = e.target.dataset.domain;

    if (this.context.router) {
      e.preventDefault();
      e.stopPropagation();
      this.context.router.history.push(`/emoji_detail/${shortcode}${domain ? `@${domain}` : ''}`);
    }
  }

  _updateStatusLinks () {
    const { intl, status, collapsable, onClick, onCollapsedToggle } = this.props;
    const node = this.node;

    if (!node) {
      return;
    }

    const reference_link = node.querySelector('.reference-link-inline > a');
    if (reference_link && reference_link?.dataset?.statusId && !reference_link.hasReferenceClick ) {
      reference_link.addEventListener('click', this.onReferenceLinkClick.bind(this, reference_link.dataset.statusId), false);
      reference_link.setAttribute('target', '_blank');
      reference_link.setAttribute('rel', 'noopener noreferrer');
      reference_link.hasReferenceClick = true;
    }

    const links = node.querySelectorAll(':not(.reference-link-inline) > a');

    for (var i = 0; i < links.length; ++i) {
      let link = links[i];
      if (link.classList.contains('status-link')) {
        continue;
      }
      link.classList.add('status-link');

      let mention = status.get('mentions').find(item => link.href === item.get('url'));

      if (link.classList.contains('custom-emoji-url-link') && link.dataset.shortcode) {
        if (link.dataset.domain) {
          link.setAttribute('title', intl.formatMessage(messages.linkToCustomEmojiInRemote, { shortcode: link.dataset.shortcode, domain: link.dataset.domain }));
        } else {
          link.setAttribute('title', intl.formatMessage(messages.linkToCustomEmojiInLocal, { shortcode: link.dataset.shortcode }));
        }
        link.addEventListener('click', this.onCustomEmojiUrlClick.bind(this, link.dataset.shortcode, link.dataset.domain), false);
      } else if (link.textContent[0] === '#' || (link.previousSibling && link.previousSibling.textContent && link.previousSibling.textContent[link.previousSibling.textContent.length - 1] === '#')) {
        link.addEventListener('click', this.onHashtagClick.bind(this, link.text), false);
      } else if (link.classList.contains('account-url-link')) {
        link.setAttribute('title', intl.formatMessage(messages.linkToAcct, { acct: link.dataset.accountAcct }));
        link.addEventListener('click', this.onAccountUrlClick.bind(this, link.dataset.accountId, link.dataset.path ?? '', link.dataset.accountActorType), false);
      } else if (link.classList.contains('status-url-link') && ![status.get('uri'), status.get('url')].includes(link.href)) {
        link.setAttribute('title', intl.formatMessage(messages.postByAcct, { acct: link.dataset.statusAccountAcct }));
        link.addEventListener('click', this.onStatusUrlClick.bind(this, link.dataset.statusId, link.dataset.path ?? ''), false);
      } else if (mention) {
        if (mention.get('group', false)) {
          link.addEventListener('click', this.onGroupMentionClick.bind(this, mention), false);
        } else {
          link.addEventListener('click', this.onMentionClick.bind(this, mention), false);
        }
        link.setAttribute('title', mention.get('acct'));
      } else {
        link.setAttribute('title', link.href);
        link.classList.add('unhandled-link');
      }

      link.setAttribute('target', '_blank');
      link.setAttribute('rel', 'noopener noreferrer');
    }

    if (status.get('collapsed', null) === null) {
      let collapsed =
          collapsable
          && onClick
          && node.clientHeight > MAX_HEIGHT
          && status.get('spoiler_text').length === 0;

      if(onCollapsedToggle) onCollapsedToggle(collapsed);

      status.set('collapsed', collapsed);
    }
  }

  handleMouseEnter = ({ currentTarget }) => {
    if (autoPlayEmoji) {
      return;
    }

    const emojis = currentTarget.querySelectorAll('.custom-emoji');

    for (var i = 0; i < emojis.length; i++) {
      let emoji = emojis[i];
      emoji.src = emoji.getAttribute('data-original');
    }
  }

  handleMouseLeave = ({ currentTarget }) => {
    if (autoPlayEmoji) {
      return;
    }

    const emojis = currentTarget.querySelectorAll('.custom-emoji');

    for (var i = 0; i < emojis.length; i++) {
      let emoji = emojis[i];
      emoji.src = emoji.getAttribute('data-static');
    }
  }

  componentDidMount () {
    this._updateStatusLinks();
    this._updateEmojiLinks();
  }

  componentDidUpdate () {
    this._updateStatusLinks();
    this._updateEmojiLinks();
  }

  onMentionClick = (mention, e) => {
    if (this.context.router && e.button === 0 && !(e.ctrlKey || e.metaKey)) {
      e.preventDefault();
      this.context.router.history.push(`/accounts/${mention.get('id')}`);
    }
  }

  onGroupMentionClick = (mention, e) => {
    if (this.context.router && e.button === 0 && !(e.ctrlKey || e.metaKey)) {
      e.preventDefault();
      this.context.router.history.push(`/timelines/groups/${mention.get('id')}`);
    }
  }

  onHashtagClick = (hashtag, e) => {
    hashtag = hashtag.replace(/^#/, '');

    if (this.context.router && e.button === 0 && !(e.ctrlKey || e.metaKey)) {
      e.preventDefault();
      this.context.router.history.push(`/timelines/tag/${hashtag}`);
    }
  }

  onAccountUrlClick = (accountId, path, accountActorType, e) => {
    if (this.context.router && e.button === 0 && !(e.ctrlKey || e.metaKey)) {
      e.preventDefault();
      this.context.router.history.push(`${accountActorType == 'Group' ? '/timelines/groups/' : '/accounts/'}${accountId}${path}`);
    }
  }

  onStatusUrlClick = (statusId, path, e) => {
    if (this.context.router && e.button === 0 && !(e.ctrlKey || e.metaKey)) {
      e.preventDefault();
      this.context.router.history.push(`/statuses/${statusId}${path}`);
    }
  }

  onQuoteClick = (statusId, e) => {
    let statusUrl = `/statuses/${statusId}`;

    if (this.context.router && e.button === 0) {
      e.preventDefault();
      this.context.router.history.push(statusUrl);
    }
  }

  onReferenceLinkClick = (statusId, e) => {
    if (this.context.router && e.button === 0 && !(e.ctrlKey || e.metaKey)) {
      e.preventDefault();
      this.context.router.history.push(`/statuses/${statusId}/references`);
    }
  }

  onCustomEmojiUrlClick = (shortcode, domain, e) => {
    if (this.context.router && e.button === 0 && !(e.ctrlKey || e.metaKey)) {
      e.preventDefault();
      this.context.router.history.push(`/emoji_detail/${shortcode}${domain ? `@${domain}` : ''}`);
    }
  }

  handleMouseDown = (e) => {
    this.startXY = [e.clientX, e.clientY];
  }

  handleMouseUp = (e) => {
    if (!this.startXY) {
      return;
    }

    const [ startX, startY ] = this.startXY;
    const [ deltaX, deltaY ] = [Math.abs(e.clientX - startX), Math.abs(e.clientY - startY)];

    let element = e.target;
    while (element) {
      if (element.localName === 'button' || element.localName === 'a' || element.localName === 'label') {
        return;
      }
      element = element.parentNode;
    }

    if (deltaX + deltaY < 5 && e.button === 0 && this.props.onClick) {
      this.props.onClick();
    }

    this.startXY = null;
  }

  viewerPair = () => viewerTranslationPair(this.props.status, this.props.translationAssumption, this.props.intl.locale);

  legacyPair = () => legacyTranslationPair(this.props.status, this.props.intl.locale);

  handleTranslate = (mode) => {
    if (!this.props.onTranslate) {
      return;
    }

    if (mode !== 'original' && !sameLanguagePair(this.viewerPair(), this.legacyPair())) {
      return;
    }

    this.props.onTranslate(mode);
  }

  handleSourceLanguage = (source) => {
    const pair = this.viewerPair();

    if (this.props.onTranslationAssumption && source !== pair.source) {
      this.props.onTranslationAssumption(this.props.status.get('id'), source, pair.target);
    }
  }

  handleTargetLanguage = (target) => {
    const pair = this.viewerPair();

    if (this.props.onTranslationAssumption && target !== pair.target) {
      this.props.onTranslationAssumption(this.props.status.get('id'), pair.source, target);
    }
  }

  renderMainText (viewMode, sourceHtml, targetHtml, sourceLang, targetLang, visible = true) {
    const textClass = classnames('status__content__text', {
      'status__content__text--visible': visible,
      'translate': viewMode !== 'bilingual',
    });

    if (viewMode === 'bilingual') {
      return (
        <BilingualContent
          className={textClass}
          sourceHtml={sourceHtml}
          targetHtml={targetHtml}
          sourceLang={sourceLang}
          targetLang={targetLang}
        />
      );
    }

    const showTranslation = viewMode === 'translated' && targetHtml;
    const html = showTranslation ? targetHtml : sourceHtml;
    const lang = showTranslation ? (targetLang || sourceLang) : sourceLang;

    return (
      <div className={textClass} lang={lang} dangerouslySetInnerHTML={{ __html: html }} />
    );
  }

  renderSpoilerText (viewMode, sourceHtml, targetHtml, sourceLang, targetLang) {
    if (viewMode === 'bilingual' && targetHtml) {
      return (
        <React.Fragment>
          <span className='status-translation-pair__source translate' lang={sourceLang} dir='auto' dangerouslySetInnerHTML={{ __html: sourceHtml }} />
          {' '}
          <span className='status-translation-pair__target' lang={targetLang} dir='auto' dangerouslySetInnerHTML={{ __html: targetHtml }} />
        </React.Fragment>
      );
    }

    const showTranslation = viewMode === 'translated' && targetHtml;
    const html = showTranslation ? targetHtml : sourceHtml;
    const lang = showTranslation ? (targetLang || sourceLang) : sourceLang;

    return <span dangerouslySetInnerHTML={{ __html: html }} lang={lang} className='translate' />;
  }

  handleSpoilerClick = (e) => {
    e.preventDefault();

    if (this.props.onExpandedToggle) {
      // The parent manages the state
      this.props.onExpandedToggle();
    } else {
      this.setState({ hidden: !this.state.hidden });
    }
  }

  setRef = (c) => {
    this.node = c;
  }

  render () {
    const { status, quote, intl } = this.props;

    const hidden = this.props.onExpandedToggle ? !this.props.expanded : this.state.hidden;
    const renderReadMore = this.props.onClick && status.get('collapsed');
    const renderViewThread = this.props.showThread && (
      status.get('in_reply_to_id') && status.get('in_reply_to_account_id') === status.getIn(['account', 'id'])
    );
    const renderShowPoll = !!status.get('poll');
    const contentLocale = normalizedContentLocale(intl.locale);
    const legacyPair = this.legacyPair();
    const viewerPair = this.viewerPair();
    const pairMatchesLegacy = sameLanguagePair(viewerPair, legacyPair);
    const sourceLanguage = translationSourceLanguage(status.get('language') || 'und', this.props.languages);
    const targetLanguages = this.props.languages?.get(sourceLanguage);
    const translationEligible = statusTranslationEligible(status, {
      loggedIn: !!me,
      contentLocale,
      targetLanguages,
      privateContentAllowed: translationPrivateContentAllowed,
    });
    const showResult = !!status.get('translation') && pairMatchesLegacy;

    const translationView = statusTranslationView(status);
    const viewMode = pairMatchesLegacy ? translationView.mode : 'original';
    const sourceLang = translationView.sourceLang || status.get('language');
    const targetLang = translationView.targetLang;
    const sourceHtml = status.get('contentHtml');
    const targetHtml = status.getIn(['translation', 'contentHtml']);
    const sourceSpoilerHtml = status.get('spoilerHtml');
    const targetSpoilerHtml = status.getIn(['translation', 'spoilerHtml']);
    const language = viewMode === 'original' ? sourceLang : (targetLang || sourceLang);
    const preferredMode = this.props.translationPreferredMode || translationPreferredMode;
    const classNames = classnames('status__content', {
      'status__content--with-action': this.props.onClick && this.context.router,
      'status__content--with-spoiler': status.get('spoiler_text').length > 0,
      'status__content--collapsed': renderReadMore,
    });

    const showThreadButton = (
      <button className='status__content__read-more-button' onClick={this.props.onClick}>
        <FormattedMessage id='status.show_thread' defaultMessage='Show thread' />
      </button>
    );

    const readMoreButton = (
      <button className='status__content__read-more-button' onClick={this.props.onClick} key='read-more'>
        <FormattedMessage id='status.read_more' defaultMessage='Read more' /><Icon id='angle-right' fixedWidth />
      </button>
    );

    const showPollButton = (
      <button className='status__content__read-more-button' onClick={this.props.onClick} key='show-poll'>
        <FormattedMessage id='status.show_poll' defaultMessage='Show poll' /><Icon id='angle-right' fixedWidth />
      </button>
    );

    const pollContainer = (
      <PollContainer pollId={status.get('poll')} lang={language} sourceLang={sourceLang} targetLang={targetLang} translationMode={viewMode} disabled={disableReactions} />
    );

    const mainText = this.renderMainText(viewMode, sourceHtml, targetHtml, sourceLang, targetLang, status.get('spoiler_text').length > 0 ? !hidden : true);
    const spoilerText = this.renderSpoilerText(viewMode, sourceSpoilerHtml, targetSpoilerHtml, sourceLang, targetLang);

    const translateButton = showTranslationBar && (
      <TranslationBar
        status={status}
        translation={status.get('translation')}
        mode={viewMode}
        pending={translationView.pending}
        preferredMode={preferredMode}
        viewerSource={viewerPair.source}
        viewerTarget={viewerPair.target}
        detectedSource={showResult ? (status.getIn(['translation', 'detected_source_language']) || '') : ''}
        showResult={showResult}
        translationEligible={translationEligible}
        canRequest={!!this.props.onTranslate}
        pairMatchesLegacy={pairMatchesLegacy}
        onSelect={this.handleTranslate}
        onChangeSource={this.handleSourceLanguage}
        onChangeTarget={this.handleTargetLanguage}
        intl={intl}
      />
    );

    if (status.get('spoiler_text').length > 0) {
      let mentionsPlaceholder = '';

      const mentionLinks = status.get('mentions').map(item => (
        <Permalink to={`${(item.get('group', false)) ? '/timelines/groups/' : '/accounts/'}${item.get('id')}`} href={item.get('url')} key={item.get('id')} className='mention'>
          @<span>{item.get('username')}</span>
        </Permalink>
      )).reduce((aggregate, item) => [...aggregate, item, ' '], []);

      const toggleText = hidden ? <FormattedMessage id='status.show_more' defaultMessage='Show more' /> : <FormattedMessage id='status.show_less' defaultMessage='Show less' />;

      if (hidden) {
        mentionsPlaceholder = <div>{mentionLinks}</div>;
      }

      return (
        <div className={classNames} ref={this.setRef} tabIndex='0' onMouseDown={this.handleMouseDown} onMouseUp={this.handleMouseUp} onMouseEnter={this.handleMouseEnter} onMouseLeave={this.handleMouseLeave}>
          <p style={{ marginBottom: hidden && status.get('mentions').isEmpty() ? '0px' : null }}>
            {spoilerText}
            {' '}
            <button tabIndex='0' className={`status__content__spoiler-link ${hidden ? 'status__content__spoiler-link--show-more' : 'status__content__spoiler-link--show-less'}`} onClick={this.handleSpoilerClick}>{toggleText}</button>
          </p>

          {mentionsPlaceholder}

          {React.cloneElement(mainText, { tabIndex: !hidden ? 0 : null })}

          {!hidden && renderShowPoll && quote ? showPollButton : pollContainer}

          {renderViewThread && showThreadButton}
          {translateButton}
        </div>
      );
    } else if (this.props.onClick) {
      const output = [
        <div className={classNames} ref={this.setRef} tabIndex='0' onMouseDown={this.handleMouseDown} onMouseUp={this.handleMouseUp} key='status-content' onMouseEnter={this.handleMouseEnter} onMouseLeave={this.handleMouseLeave}>
          {mainText}

          {renderShowPoll && quote ? showPollButton : pollContainer}

          {renderViewThread && showThreadButton}
          {translateButton}
        </div>,
      ];

      if (renderReadMore) {
        output.push(readMoreButton);
      }

      return output;
    } else {
      return (
        <div className={classNames} ref={this.setRef} tabIndex='0' onMouseEnter={this.handleMouseEnter} onMouseLeave={this.handleMouseLeave}>
          {mainText}

          {renderShowPoll && quote ? showPollButton : pollContainer}

          {renderViewThread && showThreadButton}
          {translateButton}
        </div>
      );
    }
  }

}

export default injectIntl(connect(mapStateToProps, mapDispatchToProps)(StatusContent));
