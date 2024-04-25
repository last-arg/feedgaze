document.addEventListener("DOMContentLoaded", function() {
    startup();
});

// TODO: toggle all feeds and their items

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
                const partial_open = item_list.querySelector(".partial-open");
                if (partial_open) {
                    partial_open.classList.remove("partial-open");
                    for (const item of partial_open.querySelectorAll(".feed-item")) {
                        item.classList.remove("hidden");
                    }
                }
                match_elem.setAttribute("aria-expanded", "true");
            }
            return;
        }

        match_elem = elem.closest(".js-expand-all");
        if (match_elem) {
            for (const partial of document.querySelectorAll(".partial-open")) {
                partial.classList.remove("partial-open");
                for (const item of partial.querySelectorAll(".feed-item")) {
                    item.classList.remove("hidden");
                }
            }
            for (const toggle_btn of document.querySelectorAll(".js-feed-item-toggle[aria-expanded=false]")) {
                toggle_btn.setAttribute("aria-expanded", "true");
            }            
        }

        match_elem = elem.closest(".js-collapse-all");
        if (match_elem) {
            for (const toggle_btn of document.querySelectorAll(".js-feed-item-toggle[aria-expanded=true]")) {
                toggle_btn.setAttribute("aria-expanded", "false");
            }            
        }
    })
}
