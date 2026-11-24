// Wrapper for IntersectionObserver in order to make working with it
// a bit easier. We also follow this performance advice:
// "If you need to observe multiple elements, it is both possible and
// advised to observe multiple elements using the same IntersectionObserver
// instance by calling observe() multiple times."
// https://developers.google.com/web/updates/2016/04/intersectionobserver

class IntersectionObserverWrapper {

  // Several rows can share an id. Emoji reaction lists repeat an account,
  // and that account id stays on data-id so emoji names are not copied into
  // the DOM. The node is the registration key. entry.target selects the
  // callback, reconnect watches every node, and unobserve removes only the
  // node it was given.
  registrations = new Map();
  observer = null;

  connect (options) {
    const onIntersection = (entries) => {
      entries.forEach(entry => {
        const registration = this.registrations.get(entry.target);

        if (registration) {
          registration.callback(entry);
        }
      });
    };

    if (this.observer) this.observer.disconnect();
    this.observer = new IntersectionObserver(onIntersection, options);
    this.registrations.forEach((_registration, node) => this.observer.observe(node));
  }

  observe (id, node, callback) {
    if (!node) {
      return;
    }

    this.registrations.set(node, { id, callback });
    if (this.observer) this.observer.observe(node);
  }

  unobserve (id, node) {
    if (!node) {
      return;
    }

    this.registrations.delete(node);
    if (this.observer) this.observer.unobserve(node);
  }

  disconnect () {
    if (this.observer) {
      this.registrations.clear();
      this.observer.disconnect();
      this.observer = null;
    }
  }

}

export default IntersectionObserverWrapper;
