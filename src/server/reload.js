document.addEventListener("DOMContentLoaded", function() {
  console.log("initialize SSE")
  const evtSource = new EventSource("//localhost:3888/sse", {});

  evtSource.onopen = function() {
    console.log("open sse connection")
  }

  evtSource.error = function(evt) {
    console.log("SSE error:", evt)
  }

  evtSource.onmessage = function (event) {
    console.log("message event", event.data)
  };

  evtSource.addEventListener("reload", (event) => {
    console.log("reload page")
    evtSource.close();
    location.reload();
  });

  window.onbeforeunload = function () {
    evtSource.close();
  };
});
