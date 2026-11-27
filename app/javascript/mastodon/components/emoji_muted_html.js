import React from 'react';
import PropTypes from 'prop-types';
import { ReactReduxContext } from 'react-redux';
import { emojiMutedPlainLabel, emojiMutedPlainText, emojiMuteTextIndexFromState, replaceEmojiInDisplayHtml, replaceUnicodeEmojiInPreviewHtml, UNVERIFIED_EMOJI_PLACEHOLDER } from 'mastodon/features/emoji/emoji_mute_text';
import { bindEmojiMuteHtmlSources, forgetEmojiMuteAttributeSource, forgetEmojiMuteTextSource, rememberEmojiMuteAttributeSource, rememberEmojiMuteDisplayAttribute, rememberEmojiMuteDisplayName, rememberEmojiMuteTextSource } from 'mastodon/features/emoji/emoji_mute_sources';

// One Redux subscription per mounted display node. The shared account and
// status records keep the emojify HTML. A rules change re-renders only these
// nodes, and replaceEmojiInDisplayHtml memoizes the string. Without a store
// (tests, or the signed-out shell) the original HTML is shown.

const indexFromStore = store => {
  if (!store || typeof store.getState !== 'function') {
    return undefined;
  }

  return emojiMuteTextIndexFromState(store.getState());
};

export function withEmojiMuteTextIndex(Wrapped) {
  class WithEmojiMuteTextIndex extends React.Component {

    static contextType = ReactReduxContext;

    static displayName = `withEmojiMuteTextIndex(${Wrapped.displayName || Wrapped.name || 'Component'})`;

    componentDidMount() {
      this.observe();
    }

    componentDidUpdate() {
      this.observe();
    }

    componentWillUnmount() {
      this.unobserve();
    }

    unobserve() {
      if (this.unsubscribe) {
        this.unsubscribe();
        this.unsubscribe = null;
      }

      this.observedStore = null;
    }

    observe() {
      const store = this.context && this.context.store;

      if (this.observedStore === store) {
        return;
      }

      this.unobserve();
      this.observedStore = store || null;

      if (!store) {
        return;
      }

      this.unsubscribe = store.subscribe(() => {
        const next = indexFromStore(store);

        if (next !== this.index) {
          this.index = next;
          this.forceUpdate();
        }
      });
    }

    render() {
      this.index = indexFromStore(this.context && this.context.store);

      return <Wrapped {...this.props} emojiMuteTextIndex={this.index} />;
    }

  }

  return WithEmojiMuteTextIndex;
}

const clickBound = new WeakSet();
const clickCursor = new WeakMap();
const hoverBound = new WeakMap();

export function customEmojiTarget(event) {
  const target = event && event.target;

  if (!target || typeof target.closest !== 'function') {
    return null;
  }

  return target.closest('.custom-emoji');
}

const pointEmoji = event => {
  const emoji = customEmojiTarget(event);

  if (emoji) {
    emoji.style.cursor = 'pointer';
  }
};

// Capture so a muted-or-not emoji click runs before an ancestor account link
// and before a link that wraps the image. Binding the container once keeps
// the listener after the inner HTML is replaced, and does not stack copies
// on componentDidUpdate.
export function bindCustomEmojiClick(node, handler) {
  if (!node || clickBound.has(node)) {
    return;
  }

  clickBound.add(node);
  clickCursor.set(node, pointEmoji);
  node.addEventListener('click', handler, true);
  node.addEventListener('mouseover', pointEmoji, false);
}

export function unbindCustomEmojiClick(node, handler) {
  if (!node || !clickBound.has(node)) {
    return;
  }

  const cursor = clickCursor.get(node);

  node.removeEventListener('click', handler, true);

  if (cursor) {
    node.removeEventListener('mouseover', cursor, false);
  }

  clickBound.delete(node);
  clickCursor.delete(node);
}

export function bindCustomEmojiHover(node, onEnter, onLeave) {
  if (!node || hoverBound.has(node)) {
    return;
  }

  const enter = event => {
    const emoji = customEmojiTarget(event);

    if (!emoji || emoji.contains(event.relatedTarget)) {
      return;
    }

    onEnter(emoji);
  };
  const leave = event => {
    const emoji = customEmojiTarget(event);

    if (!emoji || emoji.contains(event.relatedTarget)) {
      return;
    }

    onLeave(emoji);
  };

  hoverBound.set(node, { enter, leave });
  node.addEventListener('mouseover', enter, false);
  node.addEventListener('mouseout', leave, false);
}

export function unbindCustomEmojiHover(node) {
  const handlers = node && hoverBound.get(node);

  if (!handlers) {
    return;
  }

  node.removeEventListener('mouseover', handlers.enter, false);
  node.removeEventListener('mouseout', handlers.leave, false);
  hoverBound.delete(node);
}

class EmojiMutedHtmlInner extends React.PureComponent {

  static propTypes = {
    html: PropTypes.string,
    tag: PropTypes.string,
    className: PropTypes.string,
    plain: PropTypes.string,
    lang: PropTypes.string,
    dir: PropTypes.string,
    id: PropTypes.string,
    emojiMuteTextIndex: PropTypes.object,
  };

  bindSource = node => {
    this.node = node;

    if (node && typeof this.props.html === 'string') {
      bindEmojiMuteHtmlSources(node, this.props.html);
    }
  };

  componentDidUpdate() {
    this.bindSource(this.node);
  }

  render() {
    const { tag: Tag = 'span', html, className, plain, lang, dir, id, emojiMuteTextIndex } = this.props;
    const source = typeof html === 'string' ? html : '';
    const presented = replaceEmojiInDisplayHtml(source, emojiMuteTextIndex);
    const extra = {};

    if (id) {
      extra.id = id;
    }

    if (lang) {
      extra.lang = lang;
    }

    if (dir) {
      extra.dir = dir;
    }

    if (plain !== undefined) {
      extra.title = emojiMutedPlainLabel(plain, source, emojiMuteTextIndex);
    }

    return <Tag className={className} {...extra} ref={this.bindSource} dangerouslySetInnerHTML={{ __html: presented }} />;
  }

}

class EmojiMutedTitleInner extends React.PureComponent {

  static propTypes = {
    html: PropTypes.string,
    plain: PropTypes.string,
    tag: PropTypes.string,
    className: PropTypes.string,
    children: PropTypes.node,
    emojiMuteTextIndex: PropTypes.object,
  };

  render() {
    const { tag: Tag = 'span', html, plain, className, children, emojiMuteTextIndex } = this.props;
    const source = typeof html === 'string' ? html : '';
    const title = plain === undefined ? undefined : emojiMutedPlainLabel(plain, source, emojiMuteTextIndex);

    return <Tag className={className} title={title}>{children}</Tag>;
  }

}

class EmojiMutedPlainInner extends React.PureComponent {

  static propTypes = {
    html: PropTypes.string,
    plain: PropTypes.string,
    className: PropTypes.string,
    tag: PropTypes.string,
    format: PropTypes.func,
    emptyLabel: PropTypes.string,
    emojiMuteTextIndex: PropTypes.object,
  };

  componentDidMount() {
    this.bindDisplaySource();
    this.bindButtonName();
  }

  componentDidUpdate() {
    this.bindDisplaySource();
    this.bindButtonName();
  }

  componentWillUnmount() {
    this.releaseButtonName();
  }

  setNode = node => {
    this.node = node;
  };

  titleButton() {
    const emptyLabel = this.props.emptyLabel;

    if (typeof emptyLabel !== 'string' || emptyLabel.trim() === '' || !this.node || !this.node.closest) {
      return null;
    }

    return this.node.closest('button');
  }

  bindButtonName() {
    const button = this.titleButton();

    if (!button) {
      return;
    }

    const projected = this.node.textContent || '';
    const name = projected.trim() === '' ? this.props.emptyLabel : projected;

    if (button.getAttribute('aria-label') !== name) {
      button.setAttribute('aria-label', name);
    }

    const plain = typeof this.props.plain === 'string' ? this.props.plain : '';
    const html = typeof this.props.html === 'string' ? this.props.html : '';

    if (html !== '') {
      rememberEmojiMuteDisplayAttribute(button, 'aria-label', plain, html, this.props.emptyLabel, true);
      return;
    }

    rememberEmojiMuteAttributeSource(button, 'aria-label', plain, 'plain', this.props.emptyLabel, true);
  }

  releaseButtonName() {
    const button = this.titleButton();

    if (!button) {
      return;
    }

    button.removeAttribute('aria-label');
    forgetEmojiMuteAttributeSource(button, 'aria-label');
  }

  bindDisplaySource() {
    if (!this.node) {
      return;
    }

    const text = Array.from(this.node.childNodes).find(node => node.nodeType === Node.TEXT_NODE);

    if (!text) {
      return;
    }

    // A formatter wraps the projected string, so this node is not the raw
    // name. Drop a source left on a reused text node.
    if (typeof this.props.format === 'function') {
      forgetEmojiMuteTextSource(text);
      return;
    }

    const plain = typeof this.props.plain === 'string' ? this.props.plain : '';
    const html = this.props.html;

    if (typeof html === 'string' && html !== '') {
      rememberEmojiMuteDisplayName(text, plain, html);
      return;
    }

    rememberEmojiMuteTextSource(text, plain);
  }

  render() {
    const { html, plain, className, format, tag: Tag = 'div', emojiMuteTextIndex } = this.props;
    const value = emojiMutedPlainText(plain, typeof html === 'string' ? html : '', emojiMuteTextIndex);
    const text = typeof format === 'function' ? format(value) : value;

    return <Tag ref={this.setNode} className={className}>{text}</Tag>;
  }

}

class EmojiMutedPreviewInner extends React.PureComponent {

  static propTypes = {
    text: PropTypes.string,
    tag: PropTypes.string,
    className: PropTypes.string,
    lang: PropTypes.string,
    emojiMuteTextIndex: PropTypes.object,
  };

  render() {
    const { tag: Tag = 'div', text, className, lang, emojiMuteTextIndex } = this.props;
    const source = typeof text === 'string' ? text : '';

    return (
      <Tag
        className={className}
        lang={lang}
        dangerouslySetInnerHTML={{ __html: replaceUnicodeEmojiInPreviewHtml(source, emojiMuteTextIndex) }}
      />
    );
  }

}

class EmojiMutedAriaInner extends React.Component {

  static propTypes = {
    children: PropTypes.element.isRequired,
    labelFor: PropTypes.func.isRequired,
    emojiMuteTextIndex: PropTypes.object,
  };

  render() {
    const { children, labelFor, emojiMuteTextIndex } = this.props;

    return React.cloneElement(children, {
      'aria-label': labelFor(emojiMuteTextIndex),
    });
  }

}

class EmojiMuteSurfaceInner extends React.PureComponent {

  static propTypes = {
    children: PropTypes.node,
    emojiMuteTextIndex: PropTypes.object,
  };

  render() {
    if (this.props.emojiMuteTextIndex && this.props.emojiMuteTextIndex.suppressAll) {
      return <span className='emoji-mute-unverified'>{UNVERIFIED_EMOJI_PLACEHOLDER}</span>;
    }

    return this.props.children;
  }

}

export default withEmojiMuteTextIndex(EmojiMutedHtmlInner);
export const EmojiMuteSurface = withEmojiMuteTextIndex(EmojiMuteSurfaceInner);
export const EmojiMutedTitle = withEmojiMuteTextIndex(EmojiMutedTitleInner);
export const EmojiMutedPlain = withEmojiMuteTextIndex(EmojiMutedPlainInner);
export const EmojiMutedPreview = withEmojiMuteTextIndex(EmojiMutedPreviewInner);
export const EmojiMutedAria = withEmojiMuteTextIndex(EmojiMutedAriaInner);
