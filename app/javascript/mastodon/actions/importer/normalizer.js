import escapeTextContentForBrowser from 'escape-html';
import emojify from '../../features/emoji/emoji';
import { unescapeHTML } from '../../utils/html';
import { expandSpoilers } from '../../initial_state';

const domParser = new DOMParser();

const makeEmojiMap = record => record.emojis.reduce((obj, emoji) => {
  obj[`:${emoji.shortcode}:`] = emoji;
  return obj;
}, {});

export function normalizeAccount(account) {
  account = { ...account };
  const domain = account.acct?.split('@')[1] ?? '';

  const emojiMap = makeEmojiMap(account);
  const displayName = account.display_name.trim().length === 0 ? account.username : account.display_name;

  account.display_name_html = emojify(escapeTextContentForBrowser(displayName), emojiMap, domain);
  account.note_emojified = emojify(account.note, emojiMap, domain);
  account.note_plain = unescapeHTML(account.note);
  account.followed_message_emojified = emojify(account.followed_message, emojiMap, domain);

  if (account.fields) {
    account.fields = account.fields.map(pair => ({
      ...pair,
      name_emojified: emojify(escapeTextContentForBrowser(pair.name), emojiMap, domain),
      value_emojified: emojify(pair.value, emojiMap, domain),
      value_plain: unescapeHTML(pair.value),
    }));
  }

  if (account.moved) {
    account.moved = account.moved.id;
  }

  if (!(account.url.startsWith('http://') || account.url.startsWith('https://'))) {
    account.url = account.uri;
  }

  return account;
}

export function normalizeFilterResult(result) {
  const normalResult = { ...result };

  if (normalResult.filter && typeof normalResult.filter === 'object') {
    normalResult.filter = String(normalResult.filter.id);
  }

  return normalResult;
}

const EMOJI_PRESENTATION_CLASSES = ['emoji-single', 'emoji-multi', 'emoji-mix', 'emoji-other'];
// preformatted and non-rendered containers keep their own whitespace.
const SKIPPED_EMOJI_CONTAINERS = new Set(['PRE', 'SCRIPT', 'STYLE', 'TEXTAREA', 'NOSCRIPT', 'SVG', 'MATH']);
// Remote HTML often wraps paragraphs in one of these. Descend to the <p> or
// the inline run; do not treat the wrapper itself as an emoji paragraph.
const DESCENDABLE_EMOJI_CONTAINERS = new Set([
  'DIV', 'BLOCKQUOTE', 'UL', 'OL', 'LI', 'SECTION', 'ARTICLE', 'ASIDE',
  'FIGURE', 'FIGCAPTION', 'TABLE', 'TBODY', 'THEAD', 'TFOOT', 'TR', 'TD', 'TH',
  'HEADER', 'FOOTER', 'MAIN', 'DETAILS', 'SUMMARY', 'DL', 'DT', 'DD',
]);
// A blank line inside a text node. One newline is only a line break.
const BLANK_LINE_RE = /\r\n[^\S\n\r]*\r\n|\n[^\S\n]*\n|\r[^\S\n\r]*\r/;
// Prose is anything that is not ordinary whitespace. Newlines, nbsp, and the
// zero-width characters Mastodon inserts around emoji are not prose, so they
// cannot demote an emoji paragraph to emoji-other.
const PROSE_RE = /[^\s\u00A0\u1680\u2000-\u200D\u2028\u2029\u202F\u205F\u3000\uFEFF]/u;

const nodeListToArray = (nodeList) => {
  const nodes = [];

  for (let i = 0; i < nodeList.length; i += 1) {
    nodes.push(nodeList[i]);
  }

  return nodes;
};

const isElementNode = (node) => node && node.nodeType === Node.ELEMENT_NODE;

const isEmojiImage = (node) => isElementNode(node) && node.tagName === 'IMG' && node.classList.contains('emojione');

const isLineBreakNode = (node) => isElementNode(node) && node.tagName === 'BR';

const isWhitespaceTextNode = (node) => node && node.nodeType === Node.TEXT_NODE && !PROSE_RE.test(node.textContent || '');

const isBreakToken = (node) => isLineBreakNode(node) || isWhitespaceTextNode(node);

const newlineCount = (text) => (String(text || '').match(/\r\n|\n|\r/g) || []).length;

// Two breaks, not one. `<br><br>`, `<br>\n<br>`, and a blank line in a text
// node start a paragraph. `<br>` or `<br>\n` — including the newline Pixelfed
// nl2br leaves behind — stays inside the current paragraph.
const isParagraphBoundary = (nodes) => {
  let breaks = 0;
  let newlines = 0;

  for (let i = 0; i < nodes.length; i += 1) {
    const node = nodes[i];

    if (isLineBreakNode(node)) {
      breaks += 1;
    } else if (isWhitespaceTextNode(node)) {
      newlines += newlineCount(node.textContent);
    } else {
      return false;
    }
  }

  return breaks >= 2 || newlines >= 2;
};

const explodeBlankLineText = (node) => {
  if (!node || node.nodeType !== Node.TEXT_NODE || !BLANK_LINE_RE.test(node.textContent || '')) {
    return [node];
  }

  const parts = node.textContent.split(new RegExp(`(${BLANK_LINE_RE.source})`)).filter(part => part !== '');

  if (parts.length <= 1) {
    return [node];
  }

  const created = parts.map(part => node.ownerDocument.createTextNode(part));
  created.forEach(part => node.parentNode.insertBefore(part, node));
  node.remove();
  return created;
};

const prepareFlow = (nodes) => {
  const prepared = [];

  nodes.forEach(node => {
    explodeBlankLineText(node).forEach(part => {
      if (part) prepared.push(part);
    });
  });

  return prepared;
};

const inspectEmojiFlow = (nodes) => {
  const state = { emoji: 0, link: false, prose: false };

  const walk = (nodeList) => {
    for (let i = 0; i < nodeList.length; i += 1) {
      const node = nodeList[i];

      if (node.nodeType === Node.TEXT_NODE) {
        if (PROSE_RE.test(node.textContent || '')) state.prose = true;
      } else if (isElementNode(node)) {
        if (isEmojiImage(node)) {
          state.emoji += 1;
        } else if (node.tagName === 'A') {
          // Link text is the link, not a sentence. Emoji beside a mention,
          // hashtag, or URL is emoji-mix even when the anchor contains text.
          state.link = true;
        } else if (node.tagName !== 'BR' && !SKIPPED_EMOJI_CONTAINERS.has(node.tagName)) {
          walk(node.childNodes);
        }
      }
    }
  };

  walk(nodes);
  return state;
};

const presentationFor = (state) => {
  if (state.emoji === 0) return null;
  if (state.prose) return 'emoji-other';
  if (state.link) return 'emoji-mix';
  if (state.emoji === 1) return 'emoji-single';
  return 'emoji-multi';
};

const splitEmojiSegments = (nodes) => {
  const segments = [];
  let current = [];
  let pending = [];

  const closeSegment = () => {
    if (current.length === 0) return;
    segments.push(current);
    current = [];
  };

  nodes.forEach(node => {
    if (isBreakToken(node)) {
      pending.push(node);

      if (isParagraphBoundary(pending)) {
        closeSegment();
        pending = [];
      }

      return;
    }

    current = current.concat(pending, [node]);
    pending = [];
  });

  if (pending.length > 0) current = current.concat(pending);
  if (current.length > 0) segments.push(current);
  return segments;
};

const clearEmojiPresentation = (element) => {
  EMOJI_PRESENTATION_CLASSES.forEach(className => element.classList.remove(className));
};

const wrapEmojiSegment = (nodes, className) => {
  const span = nodes[0].ownerDocument.createElement('span');
  span.className = className;
  nodes[0].parentNode.insertBefore(span, nodes[0]);
  nodes.forEach(node => span.appendChild(node));
};

// One segment keeps the class on the paragraph, as before. A blank line
// inside that paragraph needs its own class, so only that slice is wrapped.
const assignEmojiSegments = (nodes, container) => {
  const segments = splitEmojiSegments(prepareFlow(nodes));

  if (container && segments.length <= 1) {
    clearEmojiPresentation(container);
    const className = segments.length === 1 ? presentationFor(inspectEmojiFlow(segments[0])) : null;
    if (className) container.classList.add(className);
    return;
  }

  if (container) clearEmojiPresentation(container);

  segments.forEach(segment => {
    const className = presentationFor(inspectEmojiFlow(segment));
    if (className) wrapEmojiSegment(segment, className);
  });
};

const classifyEmojiContainers = (parent) => {
  let loose = [];

  const flushLoose = () => {
    if (loose.length === 0) return;
    assignEmojiSegments(loose, null);
    loose = [];
  };

  nodeListToArray(parent.childNodes).forEach(node => {
    if (!isElementNode(node)) {
      loose.push(node);
      return;
    }

    if (node.tagName === 'P') {
      flushLoose();
      assignEmojiSegments(nodeListToArray(node.childNodes), node);
      return;
    }

    if (SKIPPED_EMOJI_CONTAINERS.has(node.tagName)) {
      flushLoose();
      return;
    }

    if (DESCENDABLE_EMOJI_CONTAINERS.has(node.tagName)) {
      flushLoose();
      classifyEmojiContainers(node);
      return;
    }

    loose.push(node);
  });

  flushLoose();
};

const applyEmojiPresentation = (html) => {
  const parsed = domParser.parseFromString(html, 'text/html');
  classifyEmojiContainers(parsed.body);
  return parsed.documentElement.innerHTML;
};

const mediaSignature = (media) => {
  if (!media || typeof media.forEach !== 'function') {
    return '';
  }

  const entries = [];

  media.forEach(item => {
    if (!item) {
      return;
    }

    const id = item.get ? item.get('id') : item.id;
    const description = item.get ? item.get('description') : item.description;
    entries.push(`${id}\u0000${description || ''}`);
  });

  entries.sort();
  return entries.join('\n');
};

const readValue = (value, key) => {
  if (!value) {
    return undefined;
  }

  return typeof value.get === 'function' ? value.get(key) : value[key];
};

const mediaPresentation = (media) => {
  if (!media || typeof media.forEach !== 'function') {
    return '';
  }

  const entries = [];

  media.forEach(item => {
    if (!item) {
      return;
    }

    const field = (key) => readValue(item, key) || '';

    entries.push([
      field('id'),
      field('type'),
      field('url'),
      field('preview_url'),
      field('remote_url'),
      field('text_url'),
      field('description'),
    ].join('\u0000'));
  });

  entries.sort();
  return entries.join('\n');
};

const cardPresentation = (card) => {
  if (!card) {
    return '';
  }

  const field = (key) => readValue(card, key) || '';

  return [field('url'), field('title'), field('description'), field('image'), field('type'), field('html')].join('\u0000');
};

const canonicalLink = (value) => String(readValue(value, 'url') || readValue(value, 'uri') || '');

// Body, links, and media can arrive twice with one updated_at: the POST
// response, then the timeline payload. Refresh the derived HTML when those
// differ. Counter-only refreshes stay on the fast path.
const presentationChanged = (oldStatus, incoming) => {
  const oldSource = canonicalTranslationSource(oldStatus.get('content'), oldStatus.get('spoiler_text'));
  const nextSource = canonicalTranslationSource(incoming.content, incoming.spoiler_text);

  if (oldSource.content !== nextSource.content || oldSource.spoilerText !== nextSource.spoilerText) {
    return true;
  }

  if (canonicalLink(oldStatus) !== canonicalLink(incoming)) {
    return true;
  }

  if (cardPresentation(oldStatus.get('card')) !== cardPresentation(incoming.card)) {
    return true;
  }

  return mediaPresentation(oldStatus.get('media_attachments')) !== mediaPresentation(incoming.media_attachments);
};

const preserveHiddenState = (oldStatus, incoming, spoilerText) => {
  if (!oldStatus || !oldStatus.has || !oldStatus.has('hidden')) {
    return false;
  }

  const oldSource = canonicalTranslationSource(oldStatus.get('content'), oldStatus.get('spoiler_text'));
  const nextSource = canonicalTranslationSource(incoming.content, incoming.spoiler_text);

  // A body or link refresh should not close a spoiler the viewer already
  // opened. Reset only when the spoiler text or sensitive flag changes.
  return oldSource.spoilerText === nextSource.spoilerText &&
    !!oldStatus.get('sensitive') === !!incoming.sensitive &&
    (oldStatus.get('spoiler_text') || '') === (spoilerText || '');
};

const pollId = (poll) => {
  if (poll === null || poll === undefined || poll === '') {
    return '';
  }

  if (typeof poll === 'string' || typeof poll === 'number') {
    return String(poll);
  }

  const id = poll.get ? poll.get('id') : poll.id;
  return (id === null || id === undefined) ? '' : String(id);
};

const pollOptionTitles = (poll) => {
  if (!poll || typeof poll === 'string' || typeof poll === 'number') {
    return null;
  }

  const options = poll.get ? poll.get('options') : poll.options;

  if (!options || typeof options.forEach !== 'function') {
    return [];
  }

  const titles = [];

  options.forEach(option => {
    if (typeof option === 'string') {
      titles.push(option);
    } else if (option && option.get) {
      titles.push(option.get('title') || '');
    } else {
      titles.push((option && option.title) || '');
    }
  });

  return titles;
};

const pollSourcesMatch = (oldStatus, incomingStatus, previousPoll) => {
  const incomingId = pollId(incomingStatus.poll);
  const storedId = pollId(oldStatus.get('poll'));

  if (incomingId !== storedId) {
    return false;
  }

  if (!incomingId) {
    return true;
  }

  if (!previousPoll) {
    return false;
  }

  const previousTitles = pollOptionTitles(previousPoll);
  const incomingTitles = pollOptionTitles(incomingStatus.poll);

  if (!previousTitles || !incomingTitles || previousTitles.length !== incomingTitles.length) {
    return false;
  }

  return previousTitles.every((title, index) => title === incomingTitles[index]);
};

// Match the CW-only rewrite in normalizeStatus. A stored status already has
// the spoiler moved into content, while a fresh payload still has an empty
// body and the text in spoiler_text. Compare those as the same source.
const canonicalTranslationSource = (content, spoilerText) => {
  const body = content || '';
  const spoiler = spoilerText || '';

  if (spoiler && !body) {
    return { content: spoiler, spoilerText: '' };
  }

  return { content: body, spoilerText: spoiler };
};

const readStatusField = (status, key) => {
  if (!status) {
    return undefined;
  }

  return typeof status.get === 'function' ? status.get(key) : status[key];
};

// Body, CW, language, and media descriptions. Poll titles are added by
// translationSourceSignature. These are the same dimensions as
// translationSourcesMatch, without using updated_at or counters.
export function statusSourceSignature(status) {
  const source = canonicalTranslationSource(readStatusField(status, 'content'), readStatusField(status, 'spoiler_text'));

  return [
    source.content,
    source.spoilerText,
    readStatusField(status, 'language') || '',
    mediaSignature(readStatusField(status, 'media_attachments')),
  ].join('\u0001');
}

export function translationSourceSignature(status, poll) {
  const statusPollId = pollId(readStatusField(status, 'poll'));
  const explicitPollId = poll ? pollId(poll) : '';
  const titles = pollOptionTitles(poll) || [];

  return [
    statusSourceSignature(status),
    explicitPollId || statusPollId,
    titles.join('\n'),
  ].join('\u0001');
}

// A stored status translation covers the body, CW, media descriptions, and
// poll options from one response. Keep it only while every one of those
// sources is unchanged, so an edited ALT or poll can be translated again.
const translationSourcesMatch = (oldStatus, incomingStatus, previousPoll) => {
  if (!oldStatus) {
    return false;
  }

  const oldSource = canonicalTranslationSource(oldStatus.get('content'), oldStatus.get('spoiler_text'));
  const incomingSource = canonicalTranslationSource(incomingStatus.content, incomingStatus.spoiler_text);

  return oldSource.content === incomingSource.content &&
    oldSource.spoilerText === incomingSource.spoilerText &&
    (oldStatus.get('language') || '') === (incomingStatus.language || '') &&
    mediaSignature(oldStatus.get('media_attachments')) === mediaSignature(incomingStatus.media_attachments) &&
    pollSourcesMatch(oldStatus, incomingStatus, previousPoll);
};

const copySignature = (normalStatus, normalOldStatus, key) => {
  const value = normalOldStatus.get(key);

  if (typeof value === 'string') {
    normalStatus[key] = value;
  }
};

const copyTranslationState = (normalStatus, normalOldStatus) => {
  if (normalOldStatus.get('translation')) {
    normalStatus.translation = normalOldStatus.get('translation');

    if (normalOldStatus.get('translationMode')) {
      normalStatus.translationMode = normalOldStatus.get('translationMode');
    }
  }

  if (normalOldStatus.get('translationPending')) {
    normalStatus.translationPending = true;

    if (normalOldStatus.get('translationRequestId')) {
      normalStatus.translationRequestId = normalOldStatus.get('translationRequestId');
    }
  }

  // A wrapper refresh keeps the attached translation or in-flight request.
  // The source signatures have to travel with that state, or the next
  // Translate click treats a still-valid personal boost as stale.
  if (normalStatus.translation || normalStatus.translationPending) {
    copySignature(normalStatus, normalOldStatus, 'translationContentSignature');
    copySignature(normalStatus, normalOldStatus, 'translationStatusSignature');
  }
};

const preserveMediaTranslations = (mediaAttachments, normalOldStatus) => {
  const previousMedia = normalOldStatus && normalOldStatus.get('media_attachments');

  return mediaAttachments?.map((media, i) => {
    const item = { ...media, order: i };

    if (previousMedia) {
      const oldItem = previousMedia.find(attachment => attachment.get('id') === item.id);

      if (oldItem && oldItem.get('description') === item.description && oldItem.get('translation')) {
        item.translation = oldItem.get('translation');
      }
    }

    return item;
  });
};

const preserveStoredStatus = (oldStatus) => {
  const kept = oldStatus.toJS();

  ['media_attachments', 'translation', 'card', 'poll', 'emojis', 'mentions', 'tags', 'filtered'].forEach((key) => {
    if (oldStatus.has(key)) {
      kept[key] = oldStatus.get(key);
    }
  });

  return kept;
};

export function normalizeStatus(status, normalOldStatus, domain, previousPoll, options = {}) {
  const normalStatus   = { ...status };
  const acceptPresentationChange = !options || options.acceptPresentationChange !== false;

  // A POST echo must not replace an official copy, even when updated_at differs.
  // Streaming can carry a later stamp or a richer card and media URL.
  if (normalOldStatus && acceptPresentationChange === false) {
    return preserveStoredStatus(normalOldStatus);
  }

  if (typeof status.account === 'object') {
    normalStatus.account = status.account.id;
  }

  if (status.reblog && status.reblog.id) {
    normalStatus.reblog = status.reblog.id;
  }

  if (status.poll && status.poll.id) {
    normalStatus.poll = status.poll.id;
  }

  if (status.filtered) {
    normalStatus.filtered = status.filtered.map(normalizeFilterResult);
  }

  // Only calculate these values when status first encountered and the
  // visible body, links, and media are unchanged. A same updated_at with a
  // new body or attachment still re-normalizes. Pass
  // acceptPresentationChange: false to keep an already official copy when a
  // later POST echo would otherwise replace it.
  const sameStamp = normalOldStatus && normalStatus.updated_at === normalOldStatus.get('updated_at');
  const refreshPresentation = sameStamp && acceptPresentationChange && presentationChanged(normalOldStatus, status);

  if (sameStamp && !refreshPresentation) {
    normalStatus.search_index = normalOldStatus.get('search_index');
    normalStatus.shortHtml = normalOldStatus.get('shortHtml');
    normalStatus.contentHtml = normalOldStatus.get('contentHtml');
    normalStatus.spoilerHtml = normalOldStatus.get('spoilerHtml');
    normalStatus.spoiler_text = normalOldStatus.get('spoiler_text');
    normalStatus.hidden = normalOldStatus.get('hidden');
    normalStatus.visibility = normalOldStatus.get('visibility');
    normalStatus.media_attachments = normalOldStatus.get('media_attachments');

    if (pollSourcesMatch(normalOldStatus, status, previousPoll)) {
      copyTranslationState(normalStatus, normalOldStatus);
    }
  } else {
    // If the status has a CW but no contents, treat the CW as if it were the
    // status' contents, to avoid having a CW toggle with seemingly no effect.
    if (normalStatus.spoiler_text && !normalStatus.content) {
      normalStatus.content = normalStatus.spoiler_text;
      normalStatus.spoiler_text = '';
    }

    const spoilerText   = normalStatus.spoiler_text || '';
    // A CW-only post is shown as body text, but the API content is still empty.
    // Index that displayed text so translation (and screen readers) see it.
    const indexedContent = (!status.content && normalStatus.content) ? normalStatus.content : status.content;
    const searchContent  = ([spoilerText, indexedContent].concat((status.poll && status.poll.options) ? status.poll.options.map(option => option.title) : [])).join('\n\n').replace(/<br\s*\/?>/g, '\n').replace(/<\/p><p>/g, '\n\n');
    const emojiMap       = makeEmojiMap(normalStatus);

    const docContentElem = domParser.parseFromString(searchContent, 'text/html').documentElement;
    if (normalStatus.quote !== null) {
      docContentElem.querySelector('.quote-inline')?.remove();
    }
    docContentElem.querySelector('.reference-link-inline')?.remove();
    docContentElem.querySelector('.original-media-link')?.remove();

    normalStatus.search_index      = docContentElem.textContent;
    normalStatus.shortHtml         = '<p>'+emojify(normalStatus.search_index.substr(0, 150), emojiMap, domain) + (normalStatus.search_index.substr(150) ? '...' : '')+'</p>';
    normalStatus.contentHtml       = applyEmojiPresentation(emojify(normalStatus.content, emojiMap, domain));
    normalStatus.spoilerHtml       = emojify(escapeTextContentForBrowser(spoilerText), emojiMap, domain);
    normalStatus.hidden            = expandSpoilers ? false : spoilerText.length > 0 || normalStatus.sensitive;

    if (preserveHiddenState(normalOldStatus, status, spoilerText)) {
      normalStatus.hidden = normalOldStatus.get('hidden');
    }

    normalStatus.visibility        = normalStatus.visibility_ex ? normalStatus.visibility_ex : normalStatus.visibility;
    normalStatus.quote             = null;
    normalStatus.media_attachments = preserveMediaTranslations(status.media_attachments, normalOldStatus);

    if (normalOldStatus && translationSourcesMatch(normalOldStatus, status, previousPoll)) {
      copyTranslationState(normalStatus, normalOldStatus);
    }

    if (normalStatus.url && !(normalStatus.url.startsWith('http://') || normalStatus.url.startsWith('https://'))) {
      normalStatus.url = null;
    }

    normalStatus.url = normalStatus.url || normalStatus.uri;

    normalStatus.media_attachments.forEach(item => {
      if (item.remote_url && !(item.remote_url.startsWith('http://') || item.remote_url.startsWith('https://')))
        item.remote_url = null;
    });
  }

  return normalStatus;
}

export function normalizeStatusTranslation(translation, status, domain = '') {
  const emojis = status.get('emojis');
  const emojiMap = makeEmojiMap({ emojis: emojis ? emojis.toJS() : [] });
  let content = translation.content;
  let spoilerText = translation.spoiler_text;

  // Fedibird already moves a CW-only spoiler into the status body. The
  // translation API still returns that text as spoiler_text with an empty
  // content, so mirror the same display shape here.
  if (!(status.get('spoiler_text') || '') && spoilerText && !content) {
    content = spoilerText;
    spoilerText = '';
  }

  const normalized = {
    detected_source_language: translation.detected_source_language,
    language: translation.language,
    provider: translation.provider,
    contentHtml: applyEmojiPresentation(emojify(content, emojiMap, domain)),
    spoilerHtml: emojify(escapeTextContentForBrowser(spoilerText), emojiMap, domain),
    spoiler_text: spoilerText,
  };

  if (typeof translation.requested_source_language === 'string') {
    normalized.requested_source_language = translation.requested_source_language;
  }

  if (typeof translation.requested_target_language === 'string') {
    normalized.requested_target_language = translation.requested_target_language;
  }

  return normalized;
}

const pollRequestStillCurrent = (poll, normalOldPoll) => {
  const requestId = normalOldPoll && normalOldPoll.get('translationRequestId');
  const oldOptions = normalOldPoll && normalOldPoll.get('options');

  if (!requestId || !oldOptions || !poll.options || oldOptions.size !== poll.options.length) {
    return false;
  }

  return poll.options.every((option, index) => oldOptions.getIn([index, 'title']) === option.title);
};

export function normalizePoll(poll, normalOldPoll) {
  const normalPoll = { ...poll };
  const emojiMap = makeEmojiMap(normalPoll);

  normalPoll.options = poll.options.map((option, index) => {
    const normalOption = {
      ...option,
      voted: poll.own_votes && poll.own_votes.includes(index),
      title_emojified: emojify(escapeTextContentForBrowser(option.title), emojiMap),
    };

    if (normalOldPoll && normalOldPoll.getIn(['options', index, 'title']) === option.title) {
      const translation = normalOldPoll.getIn(['options', index, 'translation']);

      if (translation) {
        normalOption.translation = translation;
      }
    }

    return normalOption;
  });

  if (pollRequestStillCurrent(poll, normalOldPoll)) {
    normalPoll.translationRequestId = normalOldPoll.get('translationRequestId');
  }

  return normalPoll;
}

export function normalizePollOptionTranslation(translation, poll) {
  const emojis = poll && poll.get('emojis');
  const emojiMap = makeEmojiMap({ emojis: emojis ? emojis.toJS() : [] });

  return {
    ...translation,
    titleHtml: emojify(escapeTextContentForBrowser(translation.title), emojiMap),
  };
}

export function normalizeAnnouncement(announcement) {
  const normalAnnouncement = { ...announcement };
  const emojiMap = makeEmojiMap(normalAnnouncement);

  normalAnnouncement.contentHtml = emojify(normalAnnouncement.content, emojiMap);

  return normalAnnouncement;
}

export function normalizeCustomEmojiDetail(emoji) {
  const normalEmoji   = { ...emoji };

  if (typeof emoji.creator === 'object') {
    normalEmoji.creator = creator.creator.id;
  }

  normalEmoji.shortcode_with_domain = `${emoji.shortcode}${emoji.local ? '' : `@${emoji.domain}`}`;
  normalEmoji.aliases = emoji.aliases?.map( alias => alias ? escapeTextContentForBrowser(alias) : null );
  normalEmoji.category = emoji.category ? escapeTextContentForBrowser(emoji.category) : null;
  normalEmoji.org_category = emoji.org_category ? escapeTextContentForBrowser(emoji.org_category) : null;

  return normalEmoji;
}
