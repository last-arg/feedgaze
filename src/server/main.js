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
