import React from 'react';
import PropTypes from 'prop-types';
import { ReactReduxContext } from 'react-redux';
import { emojiMutedPlainLabel, replaceEmojiInDisplayHtml, replaceInTextIndexFromRules } from 'mastodon/features/emoji/emoji_mute_text';

// One Redux subscription per mounted display node. The shared account and
// status records keep the emojify HTML. A rules change re-renders only these
// nodes, and replaceEmojiInDisplayHtml memoizes the string. Without a store
// (tests, or the signed-out shell) the original HTML is shown.

const indexFromStore = store => {
  if (!store) {
    return undefined;
  }

  const state = store.getState();
  const rules = state && typeof state.getIn === 'function' ? state.getIn(['emojiMutes', 'rules']) : undefined;

  return replaceInTextIndexFromRules(rules);
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

    return <Tag className={className} {...extra} dangerouslySetInnerHTML={{ __html: presented }} />;
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
    emojiMuteTextIndex: PropTypes.object,
  };

  render() {
    const { html, plain, className, format, tag: Tag = 'div', emojiMuteTextIndex } = this.props;
    const value = emojiMutedPlainLabel(plain, typeof html === 'string' ? html : '', emojiMuteTextIndex);
    const text = typeof format === 'function' ? format(value) : value;

    return <Tag className={className}>{text}</Tag>;
  }

}

export default withEmojiMuteTextIndex(EmojiMutedHtmlInner);
export const EmojiMutedTitle = withEmojiMuteTextIndex(EmojiMutedTitleInner);
export const EmojiMutedPlain = withEmojiMuteTextIndex(EmojiMutedPlainInner);
