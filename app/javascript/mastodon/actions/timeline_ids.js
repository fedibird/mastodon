export const publicTimelineId = ({ onlyRemote, withoutBot, withoutMedia, onlyMedia } = {}) => (
  `public${onlyRemote ? ':remote' : ''}${withoutBot ? ':nobot' : ':bot'}${withoutMedia ? ':nomedia' : ''}${onlyMedia ? ':media' : ''}`
);

export const domainTimelineId = (domain, { withoutBot, withoutMedia, onlyMedia } = {}) => (
  `domain${withoutBot ? ':nobot' : ':bot'}${withoutMedia ? ':nomedia' : ''}${onlyMedia ? ':media' : ''}:${domain}`
);

export const groupTimelineId = (id, { withoutMedia, onlyMedia, tagged } = {}) => (
  `group:${id}${withoutMedia ? ':nomedia' : ''}${onlyMedia ? ':media' : ''}${tagged ? `:${tagged}` : ''}`
);

export const hashtagTimelineId = (id) => `hashtag:${id}`;

export const personalTimelineId = ({ withoutMedia, onlyMedia } = {}) => (
  `personal${withoutMedia ? ':nomedia' : ''}${onlyMedia ? ':media' : ''}`
);

export const hashtagSplitContextKey = (id, tags) => {
  const values = (mode) => {
    const list = tags && tags[mode];

    if (!list || list.length === 0) {
      return '';
    }

    return list.map(tag => tag.value).join(',');
  };

  return `${id}|any:${values('any')}|all:${values('all')}|none:${values('none')}`;
};
