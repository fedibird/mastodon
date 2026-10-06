function fallbackCopy(text) {
  const textarea = document.createElement('textarea');

  textarea.textContent = text;
  textarea.style.position = 'fixed';
  textarea.setAttribute('readonly', '');

  document.body.appendChild(textarea);

  try {
    textarea.select();
    const copied = document.execCommand('copy');

    if (!copied) {
      return Promise.reject(new Error('copy failed'));
    }

    return Promise.resolve();
  } catch (error) {
    return Promise.reject(error);
  } finally {
    document.body.removeChild(textarea);
  }
}

export function copyText(text) {
  if (navigator.clipboard && typeof navigator.clipboard.writeText === 'function') {
    try {
      return Promise.resolve(navigator.clipboard.writeText(text)).catch(() => fallbackCopy(text));
    } catch (error) {
      return fallbackCopy(text);
    }
  }

  return fallbackCopy(text);
}
