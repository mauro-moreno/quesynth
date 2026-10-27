// What a person sees and touches in the preset browser, found the way they
// would find it: by role, by label and by the words on it, not by how the
// script happens to build it.

import {Event} from "./dom.mjs";

export const dialog = page => page.document.querySelector(".modal");
export const body = page => page.document.querySelector(".browser");
export const all = (page, selector) => page.document.querySelectorAll(selector);
export const label = el => el.textContent.trim();

// Open the browser the way the strip's button does, from the opener's focus.
export function open(page, options, opener = "preset-browse") {
  page.$(opener).focus();
  page.window.SynthBrowser.open(options);
  return body(page);
}

// The rows of the list of presets, as the options a screen reader hears.
export const options = page => all(page, '[role="option"]');
export const names = page => options(page).map(o => o.querySelector(".browser-result-name").textContent);
export const selected = page => options(page).filter(o => o.getAttribute("aria-selected") === "true")
  .map(o => o.querySelector(".browser-result-name").textContent);
export const option = (page, name) => options(page).find(o => o.querySelector(".browser-result-name").textContent === name);

export const chip = (page, text) => all(page, ".browser-chip").find(c => label(c) === text);
export const star = (page, name) => page.document.querySelector(`[aria-label="Favorite ${name}"]`);
export const tab = (page, text) => all(page, '[role="tab"]').find(t => label(t) === text);
export const searchBox = page => page.document.querySelector('[aria-label="Search presets by name"]');
export const pressed = el => el.getAttribute("aria-pressed") === "true";

// Type into a box: the value, then the event a browser fires.
export function type(page, box, text) {
  box.value = text;
  box.dispatchEvent(new Event("input", {bubbles: true}));
}

// A key pressed on an element, as the browser delivers it: from there, up.
export function press(el, key, init = {}) {
  const event = new Event("keydown", {key, bubbles: true, ...init});
  el.dispatchEvent(event);
  return event;
}

export const focused = page => page.document.activeElement;
export const settle = () => new Promise(resolve => setImmediate(resolve));

// The text of every status region in the dialog, for "was it said".
export const said = page => all(page, '.modal [role="status"]').map(label).filter(Boolean);
export const feedback = page => page.document.querySelector(".browser-feedback");
