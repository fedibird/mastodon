// Masonry wraps each article in its own div, so article:nth-of-type(n)
// only ever matches the first article. Tree order still matches the timeline.
export const articleFocusTarget = (container, index) => {
  if (!container || typeof container.querySelectorAll !== 'function' || index < 0) {
    return null;
  }

  const articles = container.querySelectorAll('article');
  const article = articles[index];

  return article ? article.querySelector('.focusable') : null;
};
