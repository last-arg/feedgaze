document.addEventListener("DOMContentLoaded", function() {
  const evtSource = new EventSource("http://localhost:3888/sse", {});

  evtSource.addEventListener("message", (event) => {
    console.log("message event", event.data)
  });

  evtSource.addEventListener("reload", (event) => {
    console.log("reload page")
    location.reload();
  });
});
