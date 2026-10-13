import React from 'react';
import AutosuggestAccountContainer from '../features/compose/containers/autosuggest_account_container';
import AutosuggestEmoji from './autosuggest_emoji';
import AutosuggestHashtag from './autosuggest_hashtag';
import ImmutablePropTypes from 'react-immutable-proptypes';
import PropTypes from 'prop-types';
import ImmutablePureComponent from 'react-immutable-pure-component';
import Textarea from 'react-textarea-autosize';
import classNames from 'classnames';

const textAtCursorMatchesToken = (str, caretPosition) => {
  let word;

  let left  = str.slice(0, caretPosition).search(/\S+$/);
  let right = str.slice(caretPosition).search(/\s/);

  if (right < 0) {
    word = str.slice(left);
  } else {
    word = str.slice(left, right + caretPosition);
  }

  if (!word || word.trim().length < 2 || ['@', ':', '#'].indexOf(word[0]) === -1) {
    return [null, null];
  }

  if (word.trim().length < 3 && ['@', '#'].indexOf(word[0]) !== -1) {
    return [null, null];
  }

  word = word.trim().toLowerCase();

  if (word.length > 0) {
    return [left + 1, word];
  } else {
    return [null, null];
  }
};

export default class AutosuggestTextarea extends ImmutablePureComponent {

  static propTypes = {
    value: PropTypes.string,
    suggestions: ImmutablePropTypes.list,
    disabled: PropTypes.bool,
    placeholder: PropTypes.string,
    onSuggestionSelected: PropTypes.func.isRequired,
    onSuggestionsClearRequested: PropTypes.func.isRequired,
    onSuggestionsFetchRequested: PropTypes.func.isRequired,
    onChange: PropTypes.func.isRequired,
    onKeyUp: PropTypes.func,
    onKeyDown: PropTypes.func,
    onPaste: PropTypes.func.isRequired,
    autoFocus: PropTypes.bool,
    lang: PropTypes.string,
    overlay: PropTypes.node,
    minRows: PropTypes.number,
    maxRows: PropTypes.number,
    rows: PropTypes.number,
    height: PropTypes.number,
  };

  static defaultProps = {
    autoFocus: true,
  };

  state = {
    suggestionsHidden: true,
    focused: false,
    selectedSuggestion: 0,
    lastToken: null,
    tokenStart: 0,
  };

  onChange = (e) => {
    const [ tokenStart, token ] = textAtCursorMatchesToken(e.target.value, e.target.selectionStart);

    if (token !== null && this.state.lastToken !== token) {
      this.setState({ lastToken: token, selectedSuggestion: 0, tokenStart });
      this.props.onSuggestionsFetchRequested(token);
    } else if (token === null) {
      this.setState({ lastToken: null });
      this.props.onSuggestionsClearRequested();
    }

    this.props.onChange(e);
  }

  onKeyDown = (e) => {
    const { suggestions, disabled } = this.props;
    const { selectedSuggestion, suggestionsHidden } = this.state;

    if (disabled) {
      e.preventDefault();
      return;
    }

    if (e.which === 229 || e.isComposing) {
      // Ignore key events during text composition
      // e.key may be a name of the physical key even in this case (e.x. Safari / Chrome on Mac)
      return;
    }

    switch(e.key) {
    case 'Escape':
      if (suggestions.size === 0 || suggestionsHidden) {
        document.querySelector('.ui').parentElement.focus();
      } else {
        e.preventDefault();
        this.setState({ suggestionsHidden: true });
      }

      break;
    case 'ArrowDown':
      if (suggestions.size > 0 && !suggestionsHidden) {
        e.preventDefault();
        this.setState({ selectedSuggestion: Math.min(selectedSuggestion + 1, suggestions.size - 1) });
      }

      break;
    case 'ArrowUp':
      if (suggestions.size > 0 && !suggestionsHidden) {
        e.preventDefault();
        this.setState({ selectedSuggestion: Math.max(selectedSuggestion - 1, 0) });
      }

      break;
    case 'Enter':
    case 'Tab':
      // Select suggestion
      if (this.state.lastToken !== null && suggestions.size > 0 && !suggestionsHidden) {
        e.preventDefault();
        e.stopPropagation();
        this.props.onSuggestionSelected(this.state.tokenStart, this.state.lastToken, suggestions.get(selectedSuggestion));
      }

      break;
    }

    if (e.defaultPrevented || !this.props.onKeyDown) {
      return;
    }

    this.props.onKeyDown(e);
  }

  onBlur = () => {
    this.setState({ suggestionsHidden: true, focused: false });
  }

  onFocus = (e) => {
    this.setState({ focused: true });
    if (this.props.onFocus) {
      this.props.onFocus(e);
    }
  }

  onSuggestionClick = (e) => {
    const suggestion = this.props.suggestions.get(e.currentTarget.getAttribute('data-index'));
    e.preventDefault();
    this.props.onSuggestionSelected(this.state.tokenStart, this.state.lastToken, suggestion);
    this.textarea.focus();
  }

  componentWillReceiveProps (nextProps) {
    if (nextProps.suggestions !== this.props.suggestions && nextProps.suggestions.size > 0 && this.state.suggestionsHidden && this.state.focused) {
      this.setState({ suggestionsHidden: false });
    }
  }

  setTextarea = (c) => {
    this.textarea = c;
  }

  componentDidMount () {
    this.syncFixedHeight();
  }

  componentDidUpdate (prevProps) {
    if (prevProps.rows !== this.props.rows || prevProps.height !== this.props.height) {
      this.syncFixedHeight();
    }
  }

  syncFixedHeight () {
    const node = this.textarea;

    if (!node || node.tagName !== 'TEXTAREA') {
      return;
    }

    if (typeof this.props.height === 'number') {
      node.style.height = `${this.props.height}px`;
      return;
    }

    if (!this.props.rows) {
      return;
    }

    const style = window.getComputedStyle(node);
    const line = parseFloat(style.lineHeight) || 22;
    const padding = (parseFloat(style.paddingTop) || 0) + (parseFloat(style.paddingBottom) || 0);
    const border = (parseFloat(style.borderTopWidth) || 0) + (parseFloat(style.borderBottomWidth) || 0);

    node.style.height = `${Math.round((this.props.rows * line) + padding + border)}px`;
  }

  onPaste = (e) => {
    if (e.clipboardData && e.clipboardData.files.length === 1) {
      this.props.onPaste(e.clipboardData.files);
      e.preventDefault();
    }
  }

  renderSuggestion = (suggestion, i) => {
    const { selectedSuggestion } = this.state;
    let inner, key;

    if (suggestion.type === 'emoji') {
      inner = <AutosuggestEmoji emoji={suggestion} />;
      key   = suggestion.id;
    } else if (suggestion.type === 'hashtag') {
      inner = <AutosuggestHashtag tag={suggestion} />;
      key   = suggestion.name;
    } else if (suggestion.type === 'account') {
      inner = <AutosuggestAccountContainer id={suggestion.id} />;
      key   = suggestion.id;
    }

    return (
      <div role='button' tabIndex='0' key={key} data-index={i} className={classNames('autosuggest-textarea__suggestions__item', { selected: i === selectedSuggestion })} onMouseDown={this.onSuggestionClick}>
        {inner}
      </div>
    );
  }

  renderTextarea (shared) {
    const { minRows, maxRows, rows, height } = this.props;

    if (rows || typeof height === 'number') {
      return (
        <textarea
          {...shared}
          rows={rows || undefined}
          data-text-rows={rows || undefined}
          ref={this.setTextarea}
        />
      );
    }

    return (
      <Textarea
        {...shared}
        ref={this.setTextarea}
        minRows={minRows}
        maxRows={maxRows}
      />
    );
  }

  render () {
    const { value, suggestions, disabled, placeholder, onKeyUp, autoFocus, children, lang, overlay } = this.props;
    const { suggestionsHidden } = this.state;
    const textarea = this.renderTextarea({
      className: 'autosuggest-textarea__textarea',
      disabled,
      placeholder,
      autoFocus,
      value,
      onChange: this.onChange,
      onKeyDown: this.onKeyDown,
      onKeyUp,
      onFocus: this.onFocus,
      onBlur: this.onBlur,
      onPaste: this.onPaste,
      dir: 'auto',
      lang,
      'aria-autocomplete': 'list',
    });

    return [
      <div className='compose-form__autosuggest-wrapper' key='autosuggest-wrapper'>
        <div className='autosuggest-textarea'>
          <label>
            <span style={{ display: 'none' }}>{placeholder}</span>
            {textarea}
          </label>
          {overlay}
        </div>
        {children}
      </div>,

      <div className='autosuggest-textarea__suggestions-wrapper' key='suggestions-wrapper'>
        <div className={`autosuggest-textarea__suggestions ${suggestionsHidden || suggestions.isEmpty() ? '' : 'autosuggest-textarea__suggestions--visible'}`}>
          {suggestions.map(this.renderSuggestion)}
        </div>
      </div>,
    ];
  }

}
