import React from 'react';
import PropTypes from 'prop-types';
import { SOURCE_TYPES } from 'mastodon/mix/source';
import messages from '../messages';

const SEARCH_TYPES = ['hashtag', 'account', 'group'];
const MEDIA_TYPES = ['personal', 'public', 'remote', 'domain', 'group'];
const BOT_TYPES = ['public', 'remote', 'domain'];
const SHOW_FIELDS = {
  home: ['hideReblog', 'hideReply', 'hidePrivate', 'hideLimited', 'hideDirect', 'hidePersonal'],
  limited: ['hideReblog', 'hideReply', 'hidePrivate', 'hideLimited', 'hideDirect', 'hidePersonal'],
  personal: ['hideReply'],
};

const initialFields = (type = 'home') => ({
  type,
  id: '',
  domain: '',
  title: '',
  tagged: '',
  any: '',
  all: '',
  none: '',
  query: '',
  onlyMedia: false,
  withoutMedia: false,
  withoutBot: false,
  withReplies: false,
  withoutReblogs: false,
  hideReblog: false,
  hideReply: false,
  hidePrivate: false,
  hideLimited: false,
  hideDirect: false,
  hidePersonal: false,
  results: [],
  searching: false,
});

const splitTags = (value) => String(value || '').split(/[,\s]+/).map(tag => tag.trim()).filter(Boolean);

class FlagToggle extends React.PureComponent {

  static propTypes = {
    name: PropTypes.string.isRequired,
    checked: PropTypes.bool,
    label: PropTypes.node.isRequired,
    onToggle: PropTypes.func.isRequired,
  };

  handleChange = (e) => {
    this.props.onToggle(this.props.name, e.target.checked);
  };

  render () {
    const { name, checked, label } = this.props;

    return (
      <label className='mix-editor__flag' htmlFor={`mix-source-${name}`}>
        <input id={`mix-source-${name}`} type='checkbox' checked={!!checked} onChange={this.handleChange} />
        {label}
      </label>
    );
  }

}

export default class SourceForm extends React.PureComponent {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    lists: PropTypes.arrayOf(PropTypes.shape({
      id: PropTypes.oneOfType([PropTypes.string, PropTypes.number]),
      title: PropTypes.string,
    })),
    onAddSource: PropTypes.func.isRequired,
    onSearch: PropTypes.func.isRequired,
  };

  static defaultProps = {
    lists: [],
  };

  state = initialFields();

  generation = 0;

  componentWillUnmount () {
    this.generation += 1;
  }

  handleType = (e) => {
    this.generation += 1;
    this.setState(initialFields(e.target.value));
  };

  handleField = (e) => {
    this.setState({ [e.target.name]: e.target.value });
  };

  handleToggle = (name, checked) => {
    if (name === 'onlyMedia' && checked) {
      this.setState({ onlyMedia: true, withoutMedia: false });
      return;
    }

    if (name === 'withoutMedia' && checked) {
      this.setState({ withoutMedia: true, onlyMedia: false });
      return;
    }

    this.setState({ [name]: checked });
  };

  handleList = (e) => {
    const id = e.target.value;
    const list = this.props.lists.find(item => String(item.id) === id);

    this.setState({ id, title: list ? list.title : '' });
  };

  handleSearch = () => {
    const generation = this.generation + 1;
    const { type, query } = this.state;

    this.generation = generation;
    this.setState({ searching: true, results: [] });

    this.props.onSearch(type, query).then(results => {
      if (this.generation !== generation) {
        return;
      }

      this.setState({ results: results || [], searching: false });
    }).catch(() => {
      if (this.generation !== generation) {
        return;
      }

      this.setState({ results: [], searching: false });
    });
  };

  handleResult = (e) => {
    const index = Number(e.currentTarget.getAttribute('data-index'));
    const result = this.state.results[index];

    if (!result) {
      return;
    }

    this.setState({ id: result.id, title: result.title, results: [], query: result.title });
  };

  buildRaw () {
    const state = this.state;
    const params = {};
    const shows = {};

    if (state.hideReblog) {
      shows.reblog = false;
    }

    if (state.hideReply) {
      shows.reply = false;
    }

    if (state.hidePrivate) {
      shows.private = false;
    }

    if (state.hideLimited) {
      shows.limited = false;
    }

    if (state.hideDirect) {
      shows.direct = false;
    }

    if (state.hidePersonal) {
      shows.personal = false;
    }

    if (['home', 'limited', 'personal'].indexOf(state.type) !== -1 && Object.keys(shows).length) {
      params.shows = shows;
    }

    if (state.onlyMedia) {
      params.onlyMedia = true;
    }

    if (state.withoutMedia) {
      params.withoutMedia = true;
    }

    if (state.withoutBot) {
      params.withoutBot = true;
    }

    if (state.withReplies) {
      params.withReplies = true;
    }

    if (state.withoutReblogs) {
      params.withoutReblogs = true;
    }

    if (state.tagged) {
      params.tagged = state.tagged;
    }

    ['any', 'all', 'none'].forEach(mode => {
      const tags = splitTags(state[mode]);

      if (tags.length) {
        params[mode] = tags;
      }
    });

    let id = state.id;

    if (state.type === 'hashtag' && !id) {
      id = state.query;
    }

    return {
      type: state.type,
      id,
      domain: state.domain,
      title: state.title,
      params,
    };
  }

  handleAdd = () => {
    if (this.props.onAddSource(this.buildRaw())) {
      const type = this.state.type;
      this.generation += 1;
      this.setState(initialFields(type));
    }
  };

  typeLabel (type) {
    const ids = {
      home: messages.home,
      limited: messages.limited,
      personal: messages.personal,
      public: messages.public,
      remote: messages.remote,
      domain: messages.domainType,
      hashtag: messages.hashtagType,
      list: messages.listType,
      group: messages.group,
      account: messages.account,
    };

    return this.props.intl.formatMessage(ids[type]);
  }

  renderFlags (names) {
    const { intl } = this.props;

    return names.map(name => (
      <FlagToggle key={name} name={name} checked={this.state[name]} label={intl.formatMessage(messages[name])} onToggle={this.handleToggle} />
    ));
  }

  render () {
    const { intl, lists } = this.props;
    const { type, results, searching } = this.state;
    const shows = SHOW_FIELDS[type] || [];

    return (
      <fieldset className='mix-editor__source-form'>
        <legend>{intl.formatMessage(messages.addSource)}</legend>

        <label className='mix-editor__label' htmlFor='mix-source-type'>{intl.formatMessage(messages.sourceType)}</label>
        <select id='mix-source-type' value={type} onChange={this.handleType}>
          {SOURCE_TYPES.map(sourceType => (
            <option key={sourceType} value={sourceType}>{this.typeLabel(sourceType)}</option>
          ))}
        </select>

        {type === 'domain' && (
          <label className='mix-editor__label' htmlFor='mix-source-domain'>
            {intl.formatMessage(messages.domain)}
            <input id='mix-source-domain' className='setting-text' name='domain' value={this.state.domain} onChange={this.handleField} />
          </label>
        )}

        {type === 'list' && (
          lists.length ? (
            <label className='mix-editor__label' htmlFor='mix-source-list'>
              {intl.formatMessage(messages.list)}
              <select id='mix-source-list' value={this.state.id} onChange={this.handleList}>
                <option value=''>{intl.formatMessage(messages.chooseList)}</option>
                {lists.map(list => (
                  <option key={list.id} value={list.id}>{list.title}</option>
                ))}
              </select>
            </label>
          ) : <p>{intl.formatMessage(messages.noLists)}</p>
        )}

        {SEARCH_TYPES.indexOf(type) !== -1 && (
          <div className='mix-editor__search'>
            <label className='mix-editor__label' htmlFor='mix-source-query'>
              {intl.formatMessage(type === 'hashtag' ? messages.hashtag : messages.search)}
              <input id='mix-source-query' className='setting-text' name='query' value={this.state.query} onChange={this.handleField} />
            </label>
            <button type='button' className='button button-secondary' onClick={this.handleSearch} aria-busy={searching}>
              {intl.formatMessage(messages.search)}
            </button>
            {results.length > 0 && (
              <ul className='mix-editor__results'>
                {results.map((result, index) => (
                  <li key={`${result.type}:${result.id}`}>
                    <button type='button' data-index={index} onClick={this.handleResult}>{result.title}</button>
                  </li>
                ))}
              </ul>
            )}
          </div>
        )}

        {type === 'hashtag' && (
          <div>
            <label className='mix-editor__label' htmlFor='mix-source-any'>
              {intl.formatMessage(messages.any)}
              <input id='mix-source-any' className='setting-text' name='any' value={this.state.any} onChange={this.handleField} />
            </label>
            <label className='mix-editor__label' htmlFor='mix-source-all'>
              {intl.formatMessage(messages.all)}
              <input id='mix-source-all' className='setting-text' name='all' value={this.state.all} onChange={this.handleField} />
            </label>
            <label className='mix-editor__label' htmlFor='mix-source-none'>
              {intl.formatMessage(messages.none)}
              <input id='mix-source-none' className='setting-text' name='none' value={this.state.none} onChange={this.handleField} />
            </label>
          </div>
        )}

        {(type === 'group' || type === 'account') && (
          <label className='mix-editor__label' htmlFor='mix-source-tagged'>
            {intl.formatMessage(messages.tagged)}
            <input id='mix-source-tagged' className='setting-text' name='tagged' value={this.state.tagged} onChange={this.handleField} />
          </label>
        )}

        {type === 'account' && this.renderFlags(['withReplies', 'withoutReblogs'])}
        {MEDIA_TYPES.indexOf(type) !== -1 && this.renderFlags(['onlyMedia', 'withoutMedia'])}
        {BOT_TYPES.indexOf(type) !== -1 && this.renderFlags(['withoutBot'])}
        {shows.length > 0 && this.renderFlags(shows)}

        <button type='button' className='button' onClick={this.handleAdd}>{intl.formatMessage(messages.addSource)}</button>
      </fieldset>
    );
  }

}
