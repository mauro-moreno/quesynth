// What a person sees and touches in the preset browser, found the way they
// would find it: by role, by label and by the words on it, not by how the
// script happens to build it.

import {Event} from "./dom.mjs";
import {FakeFileReader} from "./files.mjs";

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

// ------------------------------------------------------------ banks and files

export const sourceRow = (page, name) => all(page, ".browser-source")
  .find(r => r.querySelector(".browser-source-name").textContent === name);
export const sourceNames = page => all(page, ".browser-source").map(r => r.querySelector(".browser-source-name").textContent);
export const badges = row => [...row.querySelectorAll(".browser-badge")].map(label);

// The banks are kept behind the button that says Filters, and what is done to a
// bank, or to make one, behind a menu in them. A person who wants one opens the
// pane if it is shut and the menu if it is shut, which is what these do, and
// what they return is the item they would then press.
export const filtersToggle = page => page.document.querySelector(".browser-filters-toggle");
export function revealBanks(page) {
  const toggle = filtersToggle(page);
  if (toggle && toggle.getAttribute("aria-expanded") === "false") toggle.click();
}
function menuItems(page, scope) {
  revealBanks(page);
  const owner = page.document.querySelector(scope);
  const trigger = owner.querySelector(".browser-more");
  const list = owner.querySelector('[role="menu"]');
  if (list.hidden) trigger.click();
  return [...list.querySelectorAll('[role="menuitem"]')];
}
// New bank..., Import file..., Import folder...
export const heading = (page, text) => menuItems(page, ".browser-heading").find(b => label(b) === text);
export const headingLabels = page => menuItems(page, ".browser-heading").map(label);
export const headingMenu = page => page.document.querySelector(".browser-heading .browser-more");
// Rename..., Duplicate, Export bank, Close bank, of the bank in view.
export const tool = (page, text) => menuItems(page, ".browser-bank-tools").find(b => label(b) === text);
export const toolsMenu = page => page.document.querySelector(".browser-bank-tools .browser-more");

// Copy and Move are in the details, in a menu, for the slot that has the
// attention. A click on a slot loads it, as it always did, so the way to ask
// about a slot without loading it is the menu key or a right click on it, which
// is also what opens the menu. `ask` does that, and `slotTool` is what a person
// then reaches for: the item for Copy or Move on the slot called `name`, or
// null where the slot has no such item.
export function ask(page, cell) {
  cell.dispatchEvent(new Event("contextmenu", {bubbles: true}));
}
export function slotTool(page, kind, name) {
  const cell = all(page, ".browser-slot").find(b => label(b.querySelector(".browser-slot-name")) === name);
  if (!cell) return null;
  ask(page, cell);
  return page.document.querySelector(`[aria-label="${kind} ${name} to..."]`);
}
// The button that opens that menu, which is where the focus goes back to.
export const slotMenu = (page, name) => page.document.querySelector(`[aria-label="More actions for ${name}"]`);
export const disabled = el => el.getAttribute("aria-disabled") === "true";
export const dialogs = page => all(page, ".modal");
export const front = page => dialogs(page).at(-1);
export const submit = form => form.dispatchEvent(new Event("submit"));
export const wait = (ms = 15) => new Promise(resolve => setTimeout(resolve, ms));

// The file and download plumbing a browser gives the page, for the tests that
// open a file or export a bank.
export function withFiles(page) {
  page.downloads = [];
  page.window.Blob = Blob;
  page.window.URL = {createObjectURL: blob => { page.downloads.push(blob); return `blob:${page.downloads.length}`; }, revokeObjectURL() {}};
  page.window.FileReader = FakeFileReader;
  return page;
}

// Hand the picker a file, the way the browser's own dialog would, once the
// page has asked for one by clicking `button`.
export async function choose(page, button, file, input = 'input[type="file"]:not([webkitdirectory])') {
  button.click();
  const field = page.document.querySelector(input);
  field.files = Array.isArray(file) ? file : [file];
  field.onchange();
  await wait();
}
