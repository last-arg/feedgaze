customElements.define("time-relative", class extends HTMLElement {
  constructor() {
    super();
    const time = this.querySelector("time");
    if (time === undefined) return;
    const datetime_raw = time.getAttribute("datetime");
    if (datetime_raw === undefined) return;
    const date = new Date(datetime_raw);
    const now = Date.now();

    const seconds = Math.floor((date - now) / 1000);

    if (seconds <= 0) {
        this.prepend("Update now ");
        return;
    }

    const minutes = Math.floor(seconds / 60);
    const hours = Math.floor(minutes / 60);
    const days = Math.floor(hours / 24);
    const months = Math.floor(days / 30);
    const years = Math.floor(days / 365);
    const rel = new Intl.RelativeTimeFormat();

    let unit = "year";
    let value = years;

    if (months > 0) {
        unit = "month";
        value = months;
    } else if (days > 0) {
        unit = "day";
        value = days;
    } else if (hours > 0) {
        unit = "hour";
        value = hours;
    } else if (minutes > 0) {
        unit = "minute";
        value = minutes;
    } else {
        unit = "second";
        value = seconds;
    }

    this.prepend(`Next update ${rel.format(value, unit)} `);
  }
});

document.addEventListener("DOMContentLoaded", startup);

let has_partial_open = true;

function startup() {
    document.addEventListener("click", function(e) {
        const elem = e.target;
        let match_elem = elem.closest(".js-feed-item-toggle");
        if (match_elem) {
            const expanded = match_elem.getAttribute("aria-expanded");
            if (expanded === "true") {
                match_elem.setAttribute("aria-expanded", "false");
            } else if (expanded === "false") {
                const item_list = match_elem.closest(".feed");
                const partial_open = item_list.querySelector(".hide-after");
                if (partial_open) {
                    partial_open.classList.remove("hide-after");
                }
                match_elem.setAttribute("aria-expanded", "true");
            }
            return;
        }

        match_elem = elem.closest(".js-expand-all");
        if (match_elem) {
            remove_partial_open();

            for (const toggle_btn of document.querySelectorAll(".js-feed-item-toggle[aria-expanded=false]")) {
                toggle_btn.setAttribute("aria-expanded", "true");
            }            
        }

        match_elem = elem.closest(".js-collapse-all");
        if (match_elem) {
            remove_partial_open();

            for (const toggle_btn of document.querySelectorAll(".js-feed-item-toggle[aria-expanded=true]")) {
                toggle_btn.setAttribute("aria-expanded", "false");
            }            
        }
    })
}

function remove_partial_open() {
    if (!has_partial_open) {
        return;
    }
    for (const partial of document.querySelectorAll(".hide-after")) {
        partial.classList.remove("hide-after");
    }
    has_partial_open = false;
}
