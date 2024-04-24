document.addEventListener("DOMContentLoaded", function() {
    startup();
});

// TODO: toggle all feeds and their items

function startup() {
    document.addEventListener("click", function(e) {
        const toggle_btn = e.target.closest(".js-feed-item-toggle");
        if (toggle_btn) {
            const expanded = toggle_btn.getAttribute("aria-expanded");
            if (expanded === "true") {
                toggle_btn.setAttribute("aria-expanded", "false");
            } else if (expanded === "false") {
                const item_list = toggle_btn.closest(".feed");
                const partial_open = item_list.querySelector(".partial-open");
                if (partial_open) {
                    partial_open.classList.remove("partial-open");
                    for (const item of partial_open.querySelectorAll(".feed-item")) {
                        item.classList.remove("hidden");
                    }
                }
                toggle_btn.setAttribute("aria-expanded", "true");
            }
        }
    })
}
