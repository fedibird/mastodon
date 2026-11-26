import React from 'react';
import PropTypes from 'prop-types';
import { withEmojiMuteTextIndex } from './emoji_muted_html';
import { emojiMutedPlainText } from 'mastodon/features/emoji/emoji_mute_text';

// Updates one opted-in region label in place. The timeline that owns the
// column does not subscribe, so status rows, scroll state, and split panes
// stay mounted. Ordinary columns never call setLandmarkLabel.
class EmojiMuteColumnLandmarkInner extends React.Component {

  static propTypes = {
    column: PropTypes.func.isRequired,
    holdLabel: PropTypes.func.isRequired,
    plain: PropTypes.string.isRequired,
    html: PropTypes.string,
    project: PropTypes.bool,
    emptyLabel: PropTypes.string,
    emojiMuteTextIndex: PropTypes.object,
  };

  regionLabel(projected) {
    if (!this.props.project || typeof projected !== 'string' || projected.trim() !== '') {
      return projected;
    }

    const fallback = this.props.emptyLabel;

    return typeof fallback === 'string' && fallback.trim() !== '' ? fallback : projected;
  }

  componentDidMount() {
    this.apply();
  }

  componentDidUpdate() {
    this.apply();
  }

  componentWillUnmount() {
    this.props.holdLabel(undefined, null);
    this.write(undefined);
  }

  source() {
    if (!this.props.project) {
      return null;
    }

    const source = {
      plain: this.props.plain,
      html: typeof this.props.html === 'string' ? this.props.html : '',
    };
    const fallback = this.props.emptyLabel;

    if (typeof fallback === 'string' && fallback.trim() !== '') {
      source.emptyLabel = fallback;
      source.fallbackWhenBlank = true;
    }

    return source;
  }

  write(label) {
    const column = this.props.column();

    if (column && typeof column.setLandmarkLabel === 'function') {
      column.setLandmarkLabel(label, label === undefined ? null : this.source());
    }
  }

  apply() {
    const { plain, html, project, emojiMuteTextIndex } = this.props;
    // The visible heading already has this string. The column instance ref is
    // attached after this child's mount, so keep the label until bindColumn.
    const projected = project ? emojiMutedPlainText(plain, html || '', emojiMuteTextIndex) : plain;
    const label = this.regionLabel(projected);

    this.props.holdLabel(label, this.source());
    this.write(label);
  }

  render() {
    return null;
  }

}

const EmojiMuteColumnLandmark = withEmojiMuteTextIndex(EmojiMuteColumnLandmarkInner);

export default EmojiMuteColumnLandmark;
