import { emptyEmojiStock } from './emoji_stock';

// Production supply until a real personal set is connected.
// An empty ready stock is success. This path does not read the full
// catalog, frequently-used history, or the standard dataset, and it does
// not invent sample categories for signed-in users.
export function loadDisconnectedEmojiStock() {
  return Promise.resolve({
    status: 'ready',
    stock: emptyEmojiStock(),
  });
}
